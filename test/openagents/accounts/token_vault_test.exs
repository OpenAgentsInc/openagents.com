defmodule OpenAgents.Accounts.TokenVaultTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Accounts.TokenVault

  test "sealed tokens round-trip and never appear in the ciphertext" do
    token = "gho_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    assert {:ok, sealed} = TokenVault.seal(token)
    refute sealed =~ token
    assert {:ok, ^token} = TokenVault.open(sealed)
  end

  test "each seal is unique even for the same token" do
    assert {:ok, first} = TokenVault.seal("gho_same_token")
    assert {:ok, second} = TokenVault.seal("gho_same_token")
    refute first == second
  end

  test "tampered or malformed ciphertexts refuse to open" do
    assert {:ok, sealed} = TokenVault.seal("gho_tamper_check")
    prefix_size = byte_size(sealed) - 1
    <<prefix::binary-size(^prefix_size), last>> = sealed
    tampered = prefix <> <<Bitwise.bxor(last, 1)>>

    assert {:error, :token_unsealable} = TokenVault.open(tampered)
    assert {:error, :token_unsealable} = TokenVault.open(<<9, 1, 2, 3>>)
    assert {:error, :token_unsealable} = TokenVault.open(<<>>)
  end

  test "oversized and empty tokens are refused before encryption" do
    assert {:error, :invalid_token} = TokenVault.seal("")
    assert {:error, :invalid_token} = TokenVault.seal(String.duplicate("a", 513))
  end

  test "a missing vault key fails closed" do
    original = Application.get_env(:openagents, :github_token_encryption_key)
    assert {:ok, sealed} = TokenVault.seal("gho_key_rotation_check")

    Application.put_env(:openagents, :github_token_encryption_key, nil)
    on_exit(fn -> Application.put_env(:openagents, :github_token_encryption_key, original) end)

    assert {:error, :token_vault_not_configured} = TokenVault.seal("gho_whatever")
    assert {:error, :token_vault_not_configured} = TokenVault.open(sealed)
  end
end
