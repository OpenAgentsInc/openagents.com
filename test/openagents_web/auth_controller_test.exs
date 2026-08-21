defmodule OpenAgentsWeb.AuthControllerTest do
  use OpenAgentsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.{Accounts, Conversations, Repo, Repositories}

  setup {Req.Test, :verify_on_exit!}

  setup do
    original = Application.fetch_env!(:openagents, :github_oauth)

    Application.put_env(
      :openagents,
      :github_oauth,
      Keyword.put(original, :request_options, plug: {Req.Test, __MODULE__})
    )

    on_exit(fn -> Application.put_env(:openagents, :github_oauth, original) end)
    :ok
  end

  test "GitHub callback authenticates, renews the session, and preserves continuity", %{
    conn: conn
  } do
    conn = start_login(conn)
    {attempt, state} = attempt_and_state(conn)
    expect_github(501, "octo-person")

    authenticated =
      conn
      |> recycle()
      |> get(~p"/auth/github/callback?code=valid-code&state=#{state}")

    assert redirected_to(authenticated) == ~p"/chat"
    user_id = get_session(authenticated, "user_id")
    assert {:ok, user} = Accounts.get_active_user(user_id)
    assert user.github_id == 501
    assert get_session(authenticated, "github_oauth_attempt") == nil

    # The GitHub access token is stored sealed, never in plain text, and the
    # browser session carries only the user id.
    assert is_binary(user.github_token_ciphertext)
    refute user.github_token_ciphertext =~ "ephemeral-github-token"
    assert {:ok, "ephemeral-github-token"} = Accounts.github_token(user)
    assert user.github_token_key_id == "test-2026-08"
    assert user.github_token_scopes == ["repo", "read:org"]
    assert user.github_token_connected_at

    cookie = authenticated |> get_resp_header("set-cookie") |> Enum.join(";")
    refute cookie =~ "ephemeral-github-token"

    first_browser = authenticated |> recycle() |> get(~p"/chat")
    # The brand mark is the application's, once, in the sidebar. Chat used to
    # render a second "SARAH" mark in a header belonging to its own rail.
    assert html_response(first_browser, 200) =~ "OpenAgents"
    conversation = Conversations.get_conversation_for_user(user)

    second_browser =
      build_conn()
      |> init_test_session(%{"user_id" => user.id})

    assert {:ok, _view, _html} = live(second_browser, ~p"/chat")
    assert Conversations.get_conversation_for_user(user).id == conversation.id

    replay =
      conn
      |> recycle()
      |> get(~p"/auth/github/callback?code=valid-code&state=#{state}")

    assert redirected_to(replay) == ~p"/?auth_error=failed"
    assert get_session(replay, "user_id") == nil
    assert attempt["id"]
  end

  test "GitHub callback authenticates before the first repository exists", %{conn: conn} do
    conn = start_login(conn)
    {_attempt, state} = attempt_and_state(conn)
    expect_github(502, "empty-repository-person")
    Repositories.initial_repository!() |> Repo.delete!()

    authenticated =
      conn
      |> recycle()
      |> get(~p"/auth/github/callback?code=valid-code&state=#{state}")

    assert redirected_to(authenticated) == ~p"/chat"
    assert {:ok, _user} = authenticated |> get_session("user_id") |> Accounts.get_active_user()
  end

  test "mismatched state never reaches GitHub", %{conn: conn} do
    conn = start_login(conn)

    callback =
      conn
      |> recycle()
      |> get(~p"/auth/github/callback?code=untrusted&state=wrong")

    assert redirected_to(callback) == ~p"/?auth_error=failed"
    assert get_session(callback, "user_id") == nil
  end

  test "GitHub tools require an explicit retained-token choice", %{conn: conn} do
    refused =
      conn
      |> init_test_session(%{})
      |> put_req_header("x-csrf-token", Plug.CSRFProtection.get_csrf_token())
      |> post(~p"/auth/github")

    assert redirected_to(refused) == ~p"/?auth_error=consent_required"
    assert get_session(refused, "github_oauth_attempt") == nil
  end

  test "disconnect revokes the GitHub grant and clears local token metadata", %{conn: conn} do
    user = github_user("disconnect-github-tools")
    assert {:ok, user} = Accounts.store_github_token(user, "ephemeral-github-token")
    expect_revoke()

    disconnected =
      conn
      |> init_test_session(%{"user_id" => user.id})
      |> delete(~p"/github/connection")

    assert redirected_to(disconnected) == ~p"/chat"
    retained_identity = Accounts.get_user(user.id)
    assert retained_identity.github_token_ciphertext == nil
    assert retained_identity.github_token_key_id == nil
    assert retained_identity.github_token_scopes == []
    assert retained_identity.github_token_connected_at == nil
    assert get_session(disconnected, "user_id") == user.id
  end

  test "a provider revocation failure preserves the retained grant for a safe retry", %{
    conn: conn
  } do
    user = github_user("disconnect-provider-failure")
    assert {:ok, user} = Accounts.store_github_token(user, "ephemeral-github-token")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "DELETE"
      Plug.Conn.send_resp(conn, 503, ~s|{"message":"provider failure"}|)
    end)

    refused =
      conn
      |> init_test_session(%{"user_id" => user.id})
      |> delete(~p"/github/connection")

    assert redirected_to(refused) == ~p"/chat"
    assert get_resp_header(refused, "cache-control") == ["no-store"]
    retained = Accounts.get_user(user.id)
    assert retained.github_token_ciphertext == user.github_token_ciphertext
    assert {:ok, "ephemeral-github-token"} = Accounts.github_token(retained)
  end

  test "banned GitHub identities cannot establish a Sarah session", %{conn: conn} do
    {:ok, user} = Accounts.upsert_github_user(profile(777, "before-ban"))
    {:ok, _banned} = Accounts.ban_user(user, "manual_review")
    conn = start_login(conn)
    {_attempt, state} = attempt_and_state(conn)
    expect_github(777, "after-ban")

    callback =
      conn
      |> recycle()
      |> get(~p"/auth/github/callback?code=valid-code&state=#{state}")

    assert redirected_to(callback) == ~p"/?auth_error=banned"
    assert get_session(callback, "user_id") == nil
    assert Accounts.get_user(user.id).github_login == "after-ban"
    assert Accounts.get_user(user.id).status == "banned"
  end

  test "logout drops authority and returns to the public homepage", %{conn: conn} do
    user = github_user("logout-user")

    logged_out =
      conn
      |> init_test_session(%{"user_id" => user.id})
      |> delete(~p"/logout")

    assert redirected_to(logged_out) == ~p"/"
    assert logged_out.private.plug_session_info == :drop

    protected = logged_out |> recycle() |> get(~p"/chat")
    assert redirected_to(protected) == ~p"/"
  end

  test "session cookies are encrypted as well as signed", %{conn: conn} do
    options = OpenAgentsWeb.Endpoint.session_options()
    assert Keyword.fetch!(options, :encryption_salt)
    assert Keyword.fetch!(options, :http_only)
    assert Keyword.fetch!(options, :same_site) == "Lax"

    response = get(conn, ~p"/")
    cookie = response |> get_resp_header("set-cookie") |> Enum.join(";")
    refute cookie =~ "user_id"
    refute cookie =~ "github_oauth_attempt"
  end

  defp start_login(conn) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> init_test_session(%{})
    |> put_req_header("x-csrf-token", csrf_token)
    |> post(~p"/auth/github?github_tools=enabled")
  end

  defp attempt_and_state(conn) do
    attempt = get_session(conn, "github_oauth_attempt")
    authorization_uri = conn |> redirected_to() |> URI.parse()
    state = authorization_uri.query |> URI.decode_query() |> Map.fetch!("state")
    assert attempt["state"] == state
    {attempt, state}
  end

  defp expect_github(github_id, login) do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "ephemeral-github-token",
        "scope" => "repo,read:org"
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "id" => github_id,
        "login" => login,
        "avatar_url" => "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })
    end)
  end

  defp expect_revoke do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/applications/test-github-client-id/token"
      assert ["Basic " <> _credential] = Plug.Conn.get_req_header(conn, "authorization")
      refute Req.Test.raw_body(conn) == ""
      Plug.Conn.send_resp(conn, 204, "")
    end)
  end

  defp profile(github_id, login) do
    %{
      github_id: github_id,
      github_login: login,
      github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
    }
  end
end
