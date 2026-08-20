defmodule OpenAgents.GitHubOAuthTest do
  use OpenAgents.DataCase, async: false
  alias OpenAgents.{GitHubOAuth, Repo}
  alias OpenAgents.Accounts.OAuthAttempt

  setup {Req.Test, :verify_on_exit!}

  test "authorization attempts use state, S256 PKCE, bounded scope, and one-time receipts" do
    assert {:ok, attempt, authorization_url} = GitHubOAuth.begin_authorization()
    query = authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["client_id"] == "test-github-client-id"
    assert query["redirect_uri"] == "http://127.0.0.1:4002/auth/github/callback"
    assert query["scope"] == "read:user repo"
    assert query["state"] == attempt["state"]
    assert query["code_challenge_method"] == "S256"
    assert byte_size(query["code_challenge"]) == 43
    refute query["code_challenge"] == attempt["verifier"]

    assert :ok = GitHubOAuth.consume_attempt(attempt, attempt["state"])

    assert {:error, :invalid_oauth_state} =
             GitHubOAuth.consume_attempt(attempt, attempt["state"])
  end

  test "missing, mismatched, and expired state fail before code exchange" do
    assert {:ok, attempt, _url} = GitHubOAuth.begin_authorization()
    assert {:error, :invalid_oauth_state} = GitHubOAuth.consume_attempt(nil, "state")
    assert {:error, :invalid_oauth_state} = GitHubOAuth.consume_attempt(attempt, "wrong")

    from_attempt = Repo.get!(OAuthAttempt, attempt["id"])

    from_attempt
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :invalid_oauth_state} =
             GitHubOAuth.consume_attempt(attempt, attempt["state"])
  end

  test "code exchange and profile lookup send required headers and return bounded identity" do
    setup_req_test()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/login/oauth/access_token"
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "accept")
      assert ["OpenAgents"] = Plug.Conn.get_req_header(conn, "user-agent")
      body = Req.Test.raw_body(conn)
      assert body =~ "client_id=test-github-client-id"
      assert body =~ "client_secret=test-github-client-secret"
      assert body =~ "code=github-code"
      assert body =~ "code_verifier="
      Req.Test.json(conn, %{"access_token" => "short-lived-token", "token_type" => "bearer"})
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/user"
      assert ["Bearer short-lived-token"] = Plug.Conn.get_req_header(conn, "authorization")
      assert ["application/vnd.github+json"] = Plug.Conn.get_req_header(conn, "accept")
      assert ["2022-11-28"] = Plug.Conn.get_req_header(conn, "x-github-api-version")

      Req.Test.json(conn, %{
        "id" => 7_654,
        "login" => "octo-user",
        "avatar_url" => "https://avatars.githubusercontent.com/u/7654?v=4"
      })
    end)

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert {:ok, profile, access_token} = GitHubOAuth.exchange_and_fetch("github-code", verifier)
    assert access_token == "short-lived-token"
    assert profile.github_id == 7_654
    assert profile.github_login == "octo-user"
    assert profile.github_avatar_url == "https://avatars.githubusercontent.com/u/7654?v=4"
    assert profile.github_name == nil
  end

  test "the optional profile name is captured, trimmed, and degrades to none" do
    for {provided, expected} <- [
          {"Ada Lovelace", "Ada Lovelace"},
          {"  Ada Lovelace  ", "Ada Lovelace"},
          {"   ", nil},
          {nil, nil},
          {:absent, nil}
        ] do
      setup_req_test()

      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"access_token" => "short-lived-token"})
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        profile = %{
          "id" => 7_654,
          "login" => "octo-user",
          "avatar_url" => "https://avatars.githubusercontent.com/u/7654?v=4"
        }

        body = if provided == :absent, do: profile, else: Map.put(profile, "name", provided)
        Req.Test.json(conn, body)
      end)

      verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      # GitHub leaves `name` null far more often than not, so an unusable value
      # must degrade to no name rather than fail the login.
      assert {:ok, profile, _access_token} =
               GitHubOAuth.exchange_and_fetch("github-code", verifier)

      assert profile.github_name == expected
      assert profile.github_login == "octo-user"
    end
  end

  test "malformed provider profiles and provider failures are reduced to bounded errors" do
    setup_req_test()

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"access_token" => "provider-token"})
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "id" => 88,
        "login" => "valid-login",
        "avatar_url" => "http://attacker.example/avatar.png"
      })
    end)

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    assert {:error, :invalid_github_profile} = GitHubOAuth.exchange_and_fetch("code", verifier)
  end

  defp setup_req_test do
    original = Application.fetch_env!(:openagents, :github_oauth)

    Application.put_env(
      :openagents,
      :github_oauth,
      Keyword.put(original, :request_options, plug: {Req.Test, __MODULE__})
    )

    on_exit(fn -> Application.put_env(:openagents, :github_oauth, original) end)
    :ok
  end
end
