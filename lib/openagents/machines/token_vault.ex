defmodule OpenAgents.Machines.TokenVault do
  @moduledoc "AES-256-GCM sealing for machine tokens awaiting pairing claim."

  @version 2
  @legacy_version 1
  @aad "openagents.machine_token.v2"
  @legacy_aad "sarah.machine_token.v1"
  @nonce_bytes 12
  @tag_bytes 16
  @maximum_token_bytes 512

  @spec seal(String.t()) :: {:ok, binary()} | {:error, atom()}
  def seal(token) when is_binary(token) and byte_size(token) in 1..@maximum_token_bytes do
    with {:ok, key} <- key() do
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, token, @aad, true)

      {:ok, <<@version, nonce::binary, tag::binary, ciphertext::binary>>}
    end
  end

  def seal(_token), do: {:error, :invalid_token}

  @spec open(binary()) :: {:ok, String.t()} | {:error, atom()}
  def open(
        <<version, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>
      )
      when version in [@legacy_version, @version] do
    with {:ok, key} <- key() do
      aad = if version == @version, do: @aad, else: @legacy_aad

      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, aad, tag, false) do
        token when is_binary(token) -> {:ok, token}
        :error -> {:error, :token_unsealable}
      end
    end
  end

  def open(_sealed), do: {:error, :token_unsealable}

  defp key do
    with encoded when is_binary(encoded) <-
           Application.get_env(:openagents, :github_token_encryption_key),
         {:ok, key} when byte_size(key) == 32 <- Base.decode64(encoded) do
      {:ok, key}
    else
      _missing -> {:error, :token_vault_not_configured}
    end
  end
end
