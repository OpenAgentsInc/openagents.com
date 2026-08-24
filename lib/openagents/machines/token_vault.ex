defmodule OpenAgents.Machines.TokenVault do
  @moduledoc """
  AES-256-GCM sealing for computer tokens awaiting pairing claim.

  One version, one AAD. The retired `sarah.machine_token.v1` AAD is gone rather
  than kept as a legacy entry, because no build seals a version-1 blob and none
  can survive: a sealed token lives on a `machine_pairings` row for at most
  `OpenAgents.Machines` `@pairing_lifetime_seconds`, and both terminal
  transitions — claim and expiry — null `token_ciphertext` on the way out. A
  compatibility branch with an empty population is a name and a claim that
  nothing tests. That bound is enforced by
  `OpenAgents.Machines.expire_elapsed_pairings/0`; before it existed, expiry
  ran only when the CLI polled, so an abandoned pairing held its sealed token
  indefinitely. See `INVARIANTS.md`, CANON-002 and IDENTITY-011.

  The `openagents.machine_token.v2` AAD keeps its `machine` spelling for the
  opposite reason: it is bound into ciphertext this release did not write.

  ## Key independence

  Sealing uses `:machine_token_encryption_key` and nothing else. Until #192
  this vault read `:github_token_encryption_key` — the GitHub vault's active
  key — so the documented GitHub rotation in `docs/github-auth-plan.md` would
  have silently made every outstanding `machine_pairings.token_ciphertext`
  unopenable, and no document recorded the coupling. A missing dedicated key
  is a typed `{:error, :machine_token_vault_not_configured}` at this boundary;
  the vault never borrows another vault's key to seal. See `INVARIANTS.md`,
  VAULT-001.

  Opening tries the dedicated key first and then each key in the GitHub
  keyring — the active `:github_token_encryption_key` plus every entry in
  `:github_token_decryption_keys` — because that keyring is the only key
  material any historical record was sealed under, and because the GitHub
  rotation procedure moves a retired key into that keyring rather than
  deleting it. The fallback covers two bounded populations: pairings sealed by
  the previous release during a deploy, and pairings sealed while
  `config/runtime.exs` still bridges `:machine_token_encryption_key` to the
  GitHub key pending `MACHINE_TOKEN_ENCRYPTION_KEY` provisioning.

  The fallback deliberately never rewraps. The only reader is
  `OpenAgents.Machines.claim_locked_pairing/1`, which nulls
  `token_ciphertext` in the same transaction as a successful open — a record
  that opens does not survive to be read again, so lazy rewrap-on-read is a
  branch no execution reaches. An eager migration sweep is equally empty
  work: every record sealed under the historical key is claimed or expired
  within one `@pairing_lifetime_seconds` window, which is shorter than any
  operator response to the sweep's outcome.
  """

  @version 2
  @aad "openagents.machine_token.v2"
  @nonce_bytes 12
  @tag_bytes 16
  @maximum_token_bytes 512

  @spec seal(String.t()) :: {:ok, binary()} | {:error, atom()}
  def seal(token) when is_binary(token) and byte_size(token) in 1..@maximum_token_bytes do
    with {:ok, key} <- dedicated_key() do
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
    with {:ok, key} <- dedicated_key() do
      case decrypt(key, nonce, ciphertext, tag) do
        {:ok, token} -> {:ok, token}
        {:error, :token_unsealable} -> open_with_fallback(key, nonce, ciphertext, tag)
      end
    end
  end

  def open(_sealed), do: {:error, :token_unsealable}

  defp open_with_fallback(dedicated, nonce, ciphertext, tag) do
    dedicated
    |> historical_keys()
    |> Enum.find_value({:error, :token_unsealable}, fn key ->
      case decrypt(key, nonce, ciphertext, tag) do
        {:ok, token} -> {:ok, token}
        {:error, :token_unsealable} -> nil
      end
    end)
  end

  defp decrypt(key, nonce, ciphertext, tag) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, @aad, tag, false) do
      token when is_binary(token) -> {:ok, token}
      :error -> {:error, :token_unsealable}
    end
  end

  defp dedicated_key do
    case decode_key(Application.get_env(:openagents, :machine_token_encryption_key)) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :machine_token_vault_not_configured}
    end
  end

  # The GitHub keyring, decoded and deduplicated, minus the dedicated key that
  # already failed. Decrypt-side only: `seal/1` never sees these.
  defp historical_keys(dedicated) do
    active = Application.get_env(:openagents, :github_token_encryption_key)

    previous =
      :openagents
      |> Application.get_env(:github_token_decryption_keys, %{})
      |> Map.values()

    [active | previous]
    |> Enum.flat_map(fn encoded ->
      case decode_key(encoded) do
        {:ok, key} -> [key]
        :error -> []
      end
    end)
    |> Enum.uniq()
    |> List.delete(dedicated)
  end

  defp decode_key(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _invalid -> :error
    end
  end

  defp decode_key(_missing), do: :error
end
