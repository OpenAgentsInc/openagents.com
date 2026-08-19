defmodule OpenAgents.Memory.Portability.Envelope do
  @moduledoc "Versioned PBKDF2/AES-GCM envelope for explicit person-held memory bundles."

  alias OpenAgents.Provenance.Canonical

  @schema "sarah.portable_memory_envelope.v1"
  @kdf "pbkdf2-hmac-sha256"
  @cipher "aes-256-gcm"
  @iterations 600_000
  @maximum_envelope_bytes 512_000

  def seal(payload, passphrase) when is_map(payload) do
    with :ok <- validate_passphrase(passphrase),
         plaintext <- Canonical.encode!(payload),
         true <- byte_size(plaintext) <= 400_000 or {:error, :payload_too_large} do
      salt = :crypto.strong_rand_bytes(16)
      nonce = :crypto.strong_rand_bytes(12)
      header = header(salt, nonce)
      aad = Canonical.encode!(header)
      key = derive(passphrase, salt, @iterations)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, 16, true)

      envelope =
        Map.merge(header, %{
          "ciphertext" => Base.url_encode64(ciphertext, padding: false),
          "tag" => Base.url_encode64(tag, padding: false)
        })

      encoded = Canonical.encode!(envelope)

      if byte_size(encoded) <= @maximum_envelope_bytes,
        do: {:ok, encoded},
        else: {:error, :envelope_too_large}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def open(encoded, passphrase) when is_binary(encoded) do
    with :ok <- validate_passphrase(passphrase),
         true <- byte_size(encoded) in 1..@maximum_envelope_bytes or {:error, :invalid_envelope},
         {:ok, envelope} <- Jason.decode(encoded),
         :ok <- validate_envelope(envelope),
         {:ok, salt} <- decode(envelope["kdf"]["salt"]),
         {:ok, nonce} <- decode(envelope["cipher"]["nonce"]),
         {:ok, ciphertext} <- decode(envelope["ciphertext"]),
         {:ok, tag} <- decode(envelope["tag"]),
         header <- Map.drop(envelope, ["ciphertext", "tag"]),
         aad <- Canonical.encode!(header),
         key <- derive(passphrase, salt, envelope["kdf"]["iterations"]),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, aad, tag, false),
         {:ok, payload} <- Jason.decode(plaintext),
         true <- is_map(payload) or {:error, :invalid_payload} do
      {:ok, payload}
    else
      :error -> {:error, :decryption_failed}
      false -> {:error, :decryption_failed}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :decryption_failed}
    end
  rescue
    _error -> {:error, :invalid_envelope}
  end

  def digest(encoded) when is_binary(encoded), do: Canonical.sha256(encoded)
  def kdf_id, do: @kdf
  def cipher_id, do: @cipher

  defp header(salt, nonce),
    do: %{
      "schema" => @schema,
      "purpose" => "explicit-memory-portability",
      "kdf" => %{
        "id" => @kdf,
        "iterations" => @iterations,
        "salt" => Base.url_encode64(salt, padding: false)
      },
      "cipher" => %{
        "id" => @cipher,
        "nonce" => Base.url_encode64(nonce, padding: false),
        "tag_bytes" => 16
      }
    }

  defp validate_envelope(%{
         "schema" => @schema,
         "purpose" => "explicit-memory-portability",
         "kdf" => %{"id" => @kdf, "iterations" => @iterations, "salt" => salt},
         "cipher" => %{"id" => @cipher, "nonce" => nonce, "tag_bytes" => 16},
         "ciphertext" => ciphertext,
         "tag" => tag
       })
       when is_binary(salt) and is_binary(nonce) and is_binary(ciphertext) and is_binary(tag),
       do: :ok

  defp validate_envelope(_), do: {:error, :unsupported_envelope}

  defp validate_passphrase(value) when is_binary(value) and byte_size(value) in 12..1_024, do: :ok
  defp validate_passphrase(_), do: {:error, :invalid_passphrase}

  defp derive(passphrase, salt, iterations),
    do: :crypto.pbkdf2_hmac(:sha256, passphrase, salt, iterations, 32)

  defp decode(value) when is_binary(value), do: Base.url_decode64(value, padding: false)
  defp decode(_), do: :error
end
