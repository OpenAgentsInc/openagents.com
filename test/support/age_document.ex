defmodule OpenAgents.Test.AgeDocument do
  @moduledoc """
  An age v1 decryptor written from the specification, sharing no code with
  `OpenAgents.DataRights.Age`.

  It exists so the export encryption #178 decided can be checked where the
  `age` binary is not installed, and it is itself pinned to the reference
  implementation by `test/fixtures/age/reference.age`, a document the real
  `age` produced. Two of our own implementations agreeing would prove nothing
  on its own; that fixture is what makes the agreement mean something.

  It handles exactly one X25519 stanza, which is all the export path produces.
  """

  import Bitwise

  def file_key(document, identity) do
    {"age-secret-key-", secret} = bech32_decode(String.downcase(identity))
    {recipient, ^secret} = :crypto.generate_key(:ecdh, :x25519, secret)
    [_intro, stanza, wrapped | _rest] = String.split(document, "\n", parts: 5)
    "-> X25519 " <> ephemeral = stanza

    shared = :crypto.compute_key(:ecdh, decode(ephemeral), secret, :x25519)
    salt = decode(ephemeral) <> recipient

    open!(hkdf(shared, salt, "age-encryption.org/v1/X25519"), <<0::96>>, decode(wrapped))
  end

  def decrypt(document, identity) do
    [intro, stanza, wrapped, mac_line | _rest] = String.split(document, "\n", parts: 5)
    true = intro == "age-encryption.org/v1"
    "--- " <> mac = mac_line
    header = Enum.join([intro, stanza, wrapped, "---"], "\n")
    file_key = file_key(document, identity)

    true = :crypto.mac(:hmac, :sha256, hkdf(file_key, "", "header"), header) == decode(mac)

    prefix = byte_size(header) + byte_size(" " <> mac <> "\n")
    <<_consumed::binary-size(^prefix), nonce::binary-size(16), payload::binary>> = document
    unstream(payload, hkdf(file_key, nonce, "payload"), 0, [])
  end

  defp unstream(payload, key, counter, acc) do
    last? = byte_size(payload) <= 65_536 + 16
    size = min(byte_size(payload), 65_536 + 16)
    <<chunk::binary-size(^size), rest::binary>> = payload
    flag = if last?, do: 1, else: 0
    acc = [open!(key, <<counter::88, flag::8>>, chunk) | acc]

    if last?,
      do: acc |> Enum.reverse() |> IO.iodata_to_binary(),
      else: unstream(rest, key, counter + 1, acc)
  end

  defp open!(key, nonce, sealed) do
    size = byte_size(sealed) - 16
    <<ciphertext::binary-size(^size), tag::binary-size(16)>> = sealed

    case :crypto.crypto_one_time_aead(
           :chacha20_poly1305,
           key,
           nonce,
           ciphertext,
           <<>>,
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> plaintext
      :error -> raise "chunk did not authenticate"
    end
  end

  defp hkdf(ikm, salt, info) do
    salt = if salt == "", do: <<0::256>>, else: salt
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
  end

  defp decode(value), do: Base.decode64!(value, padding: false)

  @charset ~c"qpzry9x8gf2tvdw0s3jn54khce6mua7l"

  defp bech32_decode(string) do
    parts = String.split(string, "1")
    data = List.last(parts)
    hrp = parts |> Enum.drop(-1) |> Enum.join("1")

    bytes =
      data
      |> String.to_charlist()
      |> Enum.map(fn character -> Enum.find_index(@charset, &(&1 == character)) end)
      |> Enum.drop(-6)
      |> Enum.reduce({0, 0, []}, fn value, {accumulator, bits, bytes} ->
        drain(bor(bsl(accumulator, 5), value), bits + 5, bytes)
      end)
      |> elem(2)

    {hrp, :binary.list_to_bin(bytes)}
  end

  defp drain(accumulator, bits, bytes) when bits >= 8 do
    drain(accumulator, bits - 8, bytes ++ [band(bsr(accumulator, bits - 8), 0xFF)])
  end

  defp drain(accumulator, bits, bytes), do: {accumulator, bits, bytes}
end
