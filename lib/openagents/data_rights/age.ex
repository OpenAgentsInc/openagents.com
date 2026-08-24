defmodule OpenAgents.DataRights.Age do
  @moduledoc """
  Encrypts an export to an `age` recipient the operator does not hold.

  `EXIT-001` proves an account can obtain its own records. It says nothing
  about who else can read the document on the way out, and until now the
  answer was "the operator, and anyone the operator's transport touches",
  because the export was plain JSON over TLS. This module closes the part of
  that which can be closed: the account supplies an X25519 public key, the
  forge encrypts to it, and the private half never exists on this side of the
  boundary.

  The format is [age v1](https://age-encryption.org/v1) rather than something
  of ours, and that choice is the substance of the claim rather than a
  convenience. An export a recipient can only open with a decryptor the
  operator wrote is still an export the operator defines the terms of. `age`,
  `rage`, and every other implementation of the specification read this
  document, so the recipient depends on the operator for neither the key nor
  the reader.

  What it does not do is stated as plainly. The forge builds the export from
  plaintext PostgreSQL, so the operator holds the contents before this module
  runs and holds them still afterwards. Encryption protects the *artifact* —
  the file, its copies, whatever logs or proxies or backups the response
  passes through — and it protects nothing about the store it was read from.
  `docs/2026-08-24-private-export-encryption.md` records that boundary, the
  threat model on both sides of it, and the options rejected for the storage
  layer.

  Losing the key costs nothing here, which is the property that makes this
  decidable at all. An export is derived, not stored: an account that loses
  its private key requests the export again under a new one. That is why
  recipient-held encryption is right for the export path and wrong for the
  columns behind it, where the same key loss would be permanent.

  ## Construction

  One `X25519` recipient stanza, ChaCha20-Poly1305 over a 16-byte file key,
  an HMAC-SHA256 over the header, and the payload in `STREAM` chunks of 64
  KiB. All of it comes out of `:crypto`; no dependency is added for it.
  """

  import Bitwise

  @charset ~c"qpzry9x8gf2tvdw0s3jn54khce6mua7l"
  @hrp "age"
  @key_bytes 32
  @file_key_bytes 16
  @chunk_bytes 65_536
  @info "age-encryption.org/v1/X25519"
  @intro "age-encryption.org/v1\n"

  @typedoc "A parsed recipient: the raw 32-byte X25519 public key."
  @type recipient :: <<_::256>>

  @doc """
  Parses an `age1…` recipient into its raw X25519 public key.

  Bech32 with the `age` human-readable part, which is what `age-keygen -y`
  prints. The checksum is verified, so a transcription error is refused here
  rather than producing a document nobody can open.
  """
  @spec parse_recipient(term()) :: {:ok, recipient()} | {:error, atom()}
  def parse_recipient(recipient) when is_binary(recipient) do
    with true <- byte_size(recipient) <= 120,
         {:ok, @hrp, key} <- bech32_decode(recipient),
         @key_bytes <- byte_size(key) do
      {:ok, key}
    else
      _invalid -> {:error, :invalid_recipient}
    end
  end

  def parse_recipient(_recipient), do: {:error, :invalid_recipient}

  @doc """
  Encrypts `plaintext` to `recipient`, returning an age v1 document.

  The recipient is the raw public key from `parse_recipient/1`. An all-zero
  X25519 shared secret is refused rather than encrypted to: it means the
  recipient key has small order, and the result would be readable by anyone.
  """
  @spec encrypt(binary(), recipient()) :: {:ok, binary()} | {:error, atom()}
  def encrypt(plaintext, <<recipient::binary-size(@key_bytes)>>) when is_binary(plaintext) do
    file_key = :crypto.strong_rand_bytes(@file_key_bytes)
    {ephemeral_public, ephemeral_secret} = :crypto.generate_key(:ecdh, :x25519)
    shared = :crypto.compute_key(:ecdh, recipient, ephemeral_secret, :x25519)

    if shared == <<0::size(@key_bytes * 8)>> do
      {:error, :invalid_recipient}
    else
      wrap_key = hkdf(shared, ephemeral_public <> recipient, @info)
      wrapped = seal(wrap_key, <<0::96>>, file_key)

      header =
        @intro <>
          "-> X25519 " <>
          encode(ephemeral_public) <> "\n" <> encode(wrapped) <> "\n" <> "---"

      mac = :crypto.mac(:hmac, :sha256, hkdf(file_key, "", "header"), header)
      nonce = :crypto.strong_rand_bytes(16)
      stream_key = hkdf(file_key, nonce, "payload")

      {:ok, header <> " " <> encode(mac) <> "\n" <> nonce <> stream(plaintext, stream_key)}
    end
  rescue
    _error -> {:error, :encryption_failed}
  end

  def encrypt(_plaintext, _recipient), do: {:error, :invalid_recipient}

  # `STREAM`: each chunk carries its own tag, and the final chunk sets the
  # last byte of the nonce, so a truncated document fails to open rather than
  # opening short.
  defp stream(plaintext, key), do: stream(plaintext, key, 0, [])

  defp stream(rest, key, counter, acc) do
    last? = byte_size(rest) <= @chunk_bytes
    size = min(byte_size(rest), @chunk_bytes)
    <<chunk::binary-size(^size), remaining::binary>> = rest
    flag = if last?, do: 1, else: 0
    acc = [seal(key, <<counter::88, flag::8>>, chunk) | acc]

    if last?,
      do: acc |> Enum.reverse() |> IO.iodata_to_binary(),
      else: stream(remaining, key, counter + 1, acc)
  end

  defp seal(key, nonce, plaintext) do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, plaintext, <<>>, true)

    ciphertext <> tag
  end

  # HKDF-SHA256 to one 32-byte block. An empty salt is HashLen zeros, which is
  # what RFC 5869 says and what every age implementation does.
  defp hkdf(ikm, salt, info) do
    salt = if salt == "", do: <<0::256>>, else: salt
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
  end

  defp encode(binary), do: Base.encode64(binary, padding: false)

  defp bech32_decode(string) do
    downcased = String.downcase(string)

    with [_first, _second | _rest] = parts <- String.split(downcased, "1"),
         data = List.last(parts),
         hrp = parts |> Enum.drop(-1) |> Enum.join("1"),
         true <- hrp != "",
         {:ok, values} <- charset_values(data),
         true <- length(values) >= 6,
         1 <- polymod(hrp_expand(hrp) ++ values),
         {:ok, bytes} <- regroup(Enum.drop(values, -6)) do
      {:ok, hrp, :binary.list_to_bin(bytes)}
    else
      _invalid -> {:error, :invalid_recipient}
    end
  end

  defp charset_values(data) do
    Enum.reduce_while(String.to_charlist(data), {:ok, []}, fn character, {:ok, acc} ->
      case Enum.find_index(@charset, &(&1 == character)) do
        nil -> {:halt, {:error, :invalid_recipient}}
        index -> {:cont, {:ok, acc ++ [index]}}
      end
    end)
  end

  defp hrp_expand(hrp) do
    characters = String.to_charlist(hrp)
    Enum.map(characters, &div(&1, 32)) ++ [0] ++ Enum.map(characters, &rem(&1, 32))
  end

  @generator [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]

  defp polymod(values) do
    Enum.reduce(values, 1, fn value, checksum ->
      top = bsr(checksum, 25)
      checksum = bxor(bsl(band(checksum, 0x1FFFFFF), 5), value)

      @generator
      |> Enum.with_index()
      |> Enum.reduce(checksum, fn {constant, index}, acc ->
        if band(bsr(top, index), 1) == 1, do: bxor(acc, constant), else: acc
      end)
    end)
  end

  # 5-bit groups back to 8-bit bytes. Trailing bits must be fewer than five and
  # zero, which is what makes a padded or truncated recipient fail here.
  defp regroup(values) do
    {accumulator, bits, bytes} =
      Enum.reduce(values, {0, 0, []}, fn value, {accumulator, bits, bytes} ->
        drain(bor(bsl(accumulator, 5), value), bits + 5, bytes)
      end)

    if bits < 5 and band(bsl(accumulator, 8 - bits), 0xFF) == 0,
      do: {:ok, bytes},
      else: {:error, :invalid_recipient}
  end

  defp drain(accumulator, bits, bytes) when bits >= 8 do
    drain(accumulator, bits - 8, bytes ++ [band(bsr(accumulator, bits - 8), 0xFF)])
  end

  defp drain(accumulator, bits, bytes), do: {accumulator, bits, bytes}
end
