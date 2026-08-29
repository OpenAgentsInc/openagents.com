defmodule OpenAgentsWeb.ForgeUserControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.{Accounts, ApiTokens, GitHubOAuth}

  setup {Req.Test, :verify_on_exit!}

  setup do
    original = Application.get_env(:openagents, :github_api)

    Application.put_env(:openagents, :github_api,
      base_url: "https://github-api.internal",
      request_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn -> Application.put_env(:openagents, :github_api, original) end)
    :ok
  end

  test "GET /api/v1/user returns the GitHub identity and eligible namespaces", %{conn: conn} do
    user = github_user("forge-user", "octavia")

    {:ok, user} =
      Accounts.store_github_token(user, "github-token", GitHubOAuth.required_scopes())

    {:ok, _token, plaintext} =
      ApiTokens.create(user, %{name: "CLI status", scopes: ["forge:write"]})

    Req.Test.expect(__MODULE__, fn github_conn ->
      case github_conn.request_path do
        "/user/memberships/orgs" ->
          Req.Test.json(github_conn, [])

        path ->
          raise "unexpected GitHub path: #{path}"
      end
    end)

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> get(~p"/api/v1/user")

    assert %{
             "id" => github_id,
             "login" => "octavia",
             "namespaces" => [
               %{"id" => namespace_id, "login" => "octavia", "type" => "user"}
             ],
             "token_expires_at" => token_expires_at
           } = json_response(response, 200)

    assert github_id == user.github_id
    assert namespace_id == user.github_id
    assert {:ok, _date_time, 0} = DateTime.from_iso8601(token_expires_at)
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

  test "GET /api/v1/user accepts a repository grant that also carries sign-in scopes", %{
    conn: conn
  } do
    user = github_user("forge-user-union", "octavia-union")

    {:ok, user} =
      Accounts.store_github_token(user, "github-union-token", [
        "user:email",
        "repo",
        "read:org"
      ])

    {:ok, _token, plaintext} =
      ApiTokens.create(user, %{name: "CLI status union", scopes: ["forge:write"]})

    Req.Test.expect(__MODULE__, fn github_conn ->
      case github_conn.request_path do
        "/user/memberships/orgs" ->
          Req.Test.json(github_conn, [])

        path ->
          raise "unexpected GitHub path: #{path}"
      end
    end)

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> get(~p"/api/v1/user")

    assert %{"login" => "octavia-union", "namespaces" => namespaces} =
             json_response(response, 200)

    assert [%{"login" => "octavia-union", "type" => "user"}] = namespaces
  end

  test "GET /api/v1/user refuses a grant that lacks repository scopes", %{conn: conn} do
    user = github_user("forge-user-identity", "octavia-identity")

    {:ok, user} = Accounts.store_github_token(user, "github-identity-token", ["user:email"])

    {:ok, _token, plaintext} =
      ApiTokens.create(user, %{name: "CLI status identity", scopes: ["forge:write"]})

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> get(~p"/api/v1/user")

    assert %{
             "code" => "github_scope_required",
             "message" => "Reconnect GitHub with required access"
           } = json_response(response, 403)
  end

  test "GET /api/v1/user requires a bearer token", %{conn: conn} do
    assert %{"error" => "invalid_api_token"} =
             conn
             |> get(~p"/api/v1/user")
             |> json_response(401)
  end
end
