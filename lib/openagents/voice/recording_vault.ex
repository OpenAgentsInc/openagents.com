defmodule OpenAgents.Voice.RecordingVault do
  @moduledoc """
  AES-256-GCM sealing for call audio at rest.

  Same construction as `OpenAgents.Accounts.TokenVault`, deliberately with its own key
  and its own additional authenticated data: a credential-scoped secret must not
  be able to open a recording, and a recording key must not be able to open a
  GitHub token. The AAD also binds a chunk to its recording and sequence, so a
  sealed slice cannot be moved to another recording or reordered inside one
  without failing to open.
  """

  @nonce_bytes 12
  @tag_bytes 16
  @version 1

  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _key}, key())

  @spec seal(binary(), Ecto.UUID.t(), pos_integer()) :: {:ok, binary()} | {:error, atom()}
  def seal(plaintext, recording_id, sequence)
      when is_binary(plaintext) and byte_size(plaintext) > 0 and is_binary(recording_id) and
             is_integer(sequence) and sequence > 0 do
    with {:ok, key} <- key() do
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)
      aad = aad(recording_id, sequence)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, true)

      {:ok, <<@version, nonce::binary, tag::binary, ciphertext::binary>>}
    end
  end

  def seal(_plaintext, _recording_id, _sequence), do: {:error, :invalid_chunk}

  @spec open(binary(), Ecto.UUID.t(), pos_integer()) :: {:ok, binary()} | {:error, atom()}
  def open(
        <<@version, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>,
        recording_id,
        sequence
      )
      when is_binary(recording_id) and is_integer(sequence) and sequence > 0 do
    with {:ok, key} <- key() do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             aad(recording_id, sequence),
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :chunk_unsealable}
      end
    end
  end

  def open(_sealed, _recording_id, _sequence), do: {:error, :chunk_unsealable}

  defp aad(recording_id, sequence),
    do: "sarah.voice_recording_chunk.v1:#{recording_id}:#{sequence}"

  defp key do
    with encoded when is_binary(encoded) <-
           Application.get_env(:sarah, :voice_recording_encryption_key),
         {:ok, key} when byte_size(key) == 32 <- Base.decode64(encoded) do
      {:ok, key}
    else
      _missing -> {:error, :recording_vault_not_configured}
    end
  end
end
