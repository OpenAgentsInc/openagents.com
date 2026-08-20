defmodule OpenAgents.Accounts.TokenVault do
  @moduledoc "Versioned AES-256-GCM sealing and rotation for GitHub access tokens at rest."

  @version 2
  @legacy_version 1
  @aad_prefix "openagents.github_access_token.v2:"
  @legacy_aad "openagents.github_access_token.v1"
  @nonce_bytes 12
  @tag_bytes 16
  @maximum_token_bytes 512
  @maximum_key_id_bytes 64

  @spec seal(String.t()) :: {:ok, binary()} | {:error, atom()}
  def seal(token) when is_binary(token) and byte_size(token) in 1..@maximum_token_bytes do
    with {:ok, sealed, _key_id} <- seal_with_metadata(token), do: {:ok, sealed}
  end

  def seal(_token), do: {:error, :invalid_token}

  @spec seal_with_metadata(String.t()) ::
          {:ok, binary(), String.t()} | {:error, atom()}
  def seal_with_metadata(token)
      when is_binary(token) and byte_size(token) in 1..@maximum_token_bytes do
    with {:ok, key_id, key} <- active_key() do
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)
      aad = @aad_prefix <> key_id

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, token, aad, true)

      {:ok,
       <<@version, byte_size(key_id), key_id::binary, nonce::binary, tag::binary,
         ciphertext::binary>>, key_id}
    end
  end

  def seal_with_metadata(_token), do: {:error, :invalid_token}

  @spec open(binary()) :: {:ok, String.t()} | {:error, atom()}
  def open(<<@version, key_id_size, rest::binary>>)
      when key_id_size in 1..@maximum_key_id_bytes do
    with <<key_id::binary-size(^key_id_size), nonce::binary-size(@nonce_bytes),
           tag::binary-size(@tag_bytes), ciphertext::binary>> <- rest,
         {:ok, key} <- key_for(key_id) do
      decrypt(key, nonce, ciphertext, @aad_prefix <> key_id, tag)
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :token_unsealable}
    end
  end

  def open(
        <<@legacy_version, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>
      ) do
    case all_keys() do
      [] ->
        {:error, :token_vault_not_configured}

      keys ->
        case Enum.find_value(keys, fn key ->
               case decrypt(key, nonce, ciphertext, @legacy_aad, tag) do
                 {:ok, token} -> {:ok, token}
                 {:error, :token_unsealable} -> nil
               end
             end) do
          {:ok, token} -> {:ok, token}
          nil -> {:error, :token_unsealable}
        end
    end
  end

  def open(_sealed), do: {:error, :token_unsealable}

  @spec key_id(binary()) :: {:ok, String.t()} | {:error, atom()}
  def key_id(<<@version, key_id_size, rest::binary>>)
      when key_id_size in 1..@maximum_key_id_bytes do
    case rest do
      <<key_id::binary-size(^key_id_size), _rest::binary>> -> {:ok, key_id}
      _malformed -> {:error, :token_unsealable}
    end
  end

  def key_id(<<@legacy_version, _rest::binary>>), do: {:ok, "legacy-v1"}
  def key_id(_sealed), do: {:error, :token_unsealable}

  defp active_key do
    with key_id when is_binary(key_id) <-
           Application.get_env(:openagents, :github_token_encryption_key_id),
         true <- valid_key_id?(key_id),
         {:ok, key} <- decode_key(Application.get_env(:openagents, :github_token_encryption_key)) do
      {:ok, key_id, key}
    else
      _missing -> {:error, :token_vault_not_configured}
    end
  end

  defp key_for(key_id) do
    with {:ok, active_id, active_key} <- active_key() do
      if key_id == active_id do
        {:ok, active_key}
      else
        :openagents
        |> Application.get_env(:github_token_decryption_keys, %{})
        |> Map.get(key_id)
        |> decode_key()
      end
    end
  end

  defp all_keys do
    active =
      case active_key() do
        {:ok, _key_id, key} -> [key]
        {:error, _reason} -> []
      end

    previous =
      :openagents
      |> Application.get_env(:github_token_decryption_keys, %{})
      |> Map.values()
      |> Enum.flat_map(fn encoded ->
        case decode_key(encoded) do
          {:ok, key} -> [key]
          {:error, _reason} -> []
        end
      end)

    Enum.uniq(active ++ previous)
  end

  defp decrypt(key, nonce, ciphertext, aad, tag) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, aad, tag, false) do
      token when is_binary(token) -> {:ok, token}
      :error -> {:error, :token_unsealable}
    end
  end

  defp decode_key(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _invalid -> {:error, :token_vault_not_configured}
    end
  end

  defp decode_key(_missing), do: {:error, :token_vault_not_configured}

  defp valid_key_id?(key_id) do
    byte_size(key_id) in 1..@maximum_key_id_bytes and
      String.match?(key_id, ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/)
  end
end
