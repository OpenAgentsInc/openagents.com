defmodule OpenAgents.GitHubOAuth.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias OpenAgents.GitHubOAuth.RuntimeConfig

  test "boot fails with variable names but never credential values" do
    secret = "credential-that-must-not-appear"

    message =
      assert_raise ArgumentError, fn ->
        RuntimeConfig.load!([client_secret: secret], :prod, public_host: "stage.openagents.com")
      end

    assert message.message =~ "GITHUB_CLIENT_ID"
    assert message.message =~ "GITHUB_REDIRECT_URI"
    refute message.message =~ secret
  end

  test "production requires an exact HTTPS callback on PHX_HOST" do
    settings = settings("https://stage.openagents.com/auth/github/callback")

    assert RuntimeConfig.load!(settings, :prod, public_host: "stage.openagents.com")
           |> Map.new() == Map.new(settings)

    message =
      assert_raise ArgumentError, fn ->
        RuntimeConfig.load!(settings, :prod, public_host: "openagents.com")
      end

    assert message.message =~ "callback host must match PHX_HOST"
    refute message.message =~ "test-client-secret"
  end

  test "development permits only the canonical loopback callback" do
    settings = settings("http://127.0.0.1:4000/auth/github/callback")
    assert RuntimeConfig.load!(settings, :dev) |> Map.new() == Map.new(settings)

    assert_raise ArgumentError, fn ->
      RuntimeConfig.load!(settings("https://stage.openagents.com/auth/github/callback"), :dev)
    end
  end

  test "callback rejects query, fragment, userinfo, and the wrong path" do
    invalid_uris = [
      "https://stage.openagents.com/auth/github/callback?next=/chat",
      "https://stage.openagents.com/auth/github/callback#fragment",
      "https://user@stage.openagents.com/auth/github/callback",
      "https://stage.openagents.com/auth/github/other"
    ]

    for uri <- invalid_uris do
      assert {:error, _reason} = RuntimeConfig.validate_redirect_uri(uri)
    end
  end

  defp settings(redirect_uri) do
    [
      client_id: "test-client-id",
      client_secret: "test-client-secret",
      redirect_uri: redirect_uri
    ]
  end
end
