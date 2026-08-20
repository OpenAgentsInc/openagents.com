defmodule OpenAgents.Machines.TokenVaultTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Machines.TokenVault

  test "seals new tokens with the OpenAgents version" do
    assert {:ok, <<2, _rest::binary>> = sealed} = TokenVault.seal("smct_current")
    assert {:ok, "smct_current"} = TokenVault.open(sealed)
  end

  test "opens legacy Sarah version-1 tokens during migration" do
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

    assert {:ok, ^token} = TokenVault.open(<<1, nonce::binary, tag::binary, ciphertext::binary>>)
  end

  test "refuses unknown versions" do
    assert {:error, :token_unsealable} = TokenVault.open(<<3, 0::256>>)
  end
end
