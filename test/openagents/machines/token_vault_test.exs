defmodule OpenAgents.Machines.TokenVaultTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Machines.TokenVault

  test "seals new tokens with the OpenAgents version" do
    assert {:ok, <<2, _rest::binary>> = sealed} = TokenVault.seal("smct_current")
    assert {:ok, "smct_current"} = TokenVault.open(sealed)
  end

  # The retired `sarah.machine_token.v1` AAD is gone, not kept as a legacy
  # entry. Nothing seals a version-1 blob, and a sealed token cannot outlive
  # the ten-minute pairing window that `MachinesTest` pins, so the branch had
  # no population to serve. CANON-002.
  test "refuses retired Sarah version-1 tokens" do
    token = "smct_legacy"
    nonce = :crypto.strong_rand_bytes(12)
    {:ok, key} = Base.decode64(Application.fetch_env!(:openagents, :github_token_encryption_key))

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
end
