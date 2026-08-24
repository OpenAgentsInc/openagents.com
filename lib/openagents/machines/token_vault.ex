defmodule OpenAgents.Machines.TokenVault do
  @moduledoc """
  AES-256-GCM sealing for computer tokens awaiting pairing claim.

  One version, one AAD. The retired `sarah.machine_token.v1` AAD is gone rather
  than kept as a legacy entry, because no build seals a version-1 blob and none
  can survive: a sealed token lives on a `machine_pairings` row for at most
  `OpenAgents.Machines` `@pairing_lifetime_seconds`, and both terminal
  transitions — claim and expiry — null `token_ciphertext` on the way out. A
  compatibility branch with an empty population is a name and a claim that
  nothing tests. See `INVARIANTS.md`, CANON-002.

  The `openagents.machine_token.v2` AAD keeps its `machine` spelling for the
  opposite reason: it is bound into ciphertext this release did not write.
  """

  @version 2
  @aad "openagents.machine_token.v2"
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
      when version == @version do
    with {:ok, key} <- key() do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, @aad, tag, false) do
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
