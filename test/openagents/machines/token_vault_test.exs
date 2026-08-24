defmodule OpenAgents.Machines.TokenVaultTest do
  # These tests rebind the vault key configuration, which is global
  # application environment, so they cannot run beside async tests that read
  # the same keys.
  use ExUnit.Case, async: false

  alias OpenAgents.Machines.TokenVault

  @machine_key_setting :machine_token_encryption_key
  @github_key_setting :github_token_encryption_key
  @github_keyring_setting :github_token_decryption_keys

  setup do
    original = %{
      @machine_key_setting => Application.get_env(:openagents, @machine_key_setting),
      @github_key_setting => Application.get_env(:openagents, @github_key_setting),
      @github_keyring_setting => Application.get_env(:openagents, @github_keyring_setting)
    }

    on_exit(fn ->
      Enum.each(original, fn {setting, value} ->
        Application.put_env(:openagents, setting, value)
      end)
    end)

    :ok
  end

  test "seals new tokens with the OpenAgents version" do
    assert {:ok, <<2, _rest::binary>> = sealed} = TokenVault.seal("smct_current")
    assert {:ok, "smct_current"} = TokenVault.open(sealed)
  end

  # VAULT-001: the pairing vault reads its own key. This test turns red if
  # either side of the vault quietly reaches for the GitHub key again.
  test "seals and opens with the GitHub vault absent entirely" do
    Application.put_env(:openagents, @github_key_setting, nil)
    Application.put_env(:openagents, @github_keyring_setting, %{})

    assert {:ok, sealed} = TokenVault.seal("smct_independent")
    assert {:ok, "smct_independent"} = TokenVault.open(sealed)
  end

  test "a missing dedicated key is a typed configuration error, never a borrowed key" do
    Application.put_env(:openagents, @machine_key_setting, nil)

    assert {:error, :machine_token_vault_not_configured} = TokenVault.seal("smct_orphan")

    assert {:error, :machine_token_vault_not_configured} =
             TokenVault.open(<<2, :crypto.strong_rand_bytes(60)::binary>>)
  end

  # The historical population: every record sealed before #192 used the GitHub
  # vault's active key. The decrypt-side fallback keeps it readable for the one
  # pairing lifetime it can exist; nothing rewraps it, because the only reader
  # nulls the ciphertext in the same transaction as a successful open.
  test "a record sealed under the GitHub active key still opens" do
    github_key = Application.fetch_env!(:openagents, @github_key_setting)

    assert {:ok, "smct_historical"} =
             "smct_historical" |> sealed_under(github_key) |> TokenVault.open()
  end

  # Rehearsal 4 of docs/forge-exit-rehearsals.md: rotating the GitHub key —
  # new active key, old key moved into the decryption keyring — leaves every
  # outstanding pairing record readable.
  test "a GitHub key rotation leaves pairing records readable" do
    retired = Application.fetch_env!(:openagents, @github_key_setting)
    sealed = sealed_under("smct_survives_rotation", retired)

    Application.put_env(
      :openagents,
      @github_key_setting,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:openagents, @github_keyring_setting, %{"test-prior" => retired})

    assert {:ok, "smct_survives_rotation"} = TokenVault.open(sealed)
  end

  test "a record sealed under no known key fails closed" do
    unknown = Base.encode64(:crypto.strong_rand_bytes(32))

    assert {:error, :token_unsealable} =
             "smct_stranger" |> sealed_under(unknown) |> TokenVault.open()
  end

  # The retired `sarah.machine_token.v1` AAD is gone, not kept as a legacy
  # entry. Nothing seals a version-1 blob, and a sealed token cannot outlive
  # the ten-minute pairing window that `MachinesTest` pins, so the branch had
  # no population to serve. CANON-002.
  test "refuses retired Sarah version-1 tokens" do
    token = "smct_legacy"
    nonce = :crypto.strong_rand_bytes(12)
    {:ok, key} = Base.decode64(Application.fetch_env!(:openagents, @machine_key_setting))

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        token,
        "sarah.machine_token.v1",
        true
      )

    assert {:error, :token_unsealable} =
             TokenVault.open(<<1, nonce::binary, tag::binary, ciphertext::binary>>)
  end

  test "refuses unknown versions" do
    assert {:error, :token_unsealable} = TokenVault.open(<<3, 0::256>>)
  end

  defp sealed_under(token, encoded_key) do
    {:ok, key} = Base.decode64(encoded_key)
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        token,
        "openagents.machine_token.v2",
        true
      )

    <<2, nonce::binary, tag::binary, ciphertext::binary>>
  end
end
