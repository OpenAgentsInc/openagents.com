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

  test "GET /api/v3/user returns the GitHub identity and eligible namespaces", %{conn: conn} do
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
      |> get(~p"/api/v3/user")

    assert %{
             "id" => github_id,
             "login" => "octavia",
             "namespaces" => [
               %{"id" => namespace_id, "login" => "octavia", "type" => "user"}
             ],
             "token_expires_at" => nil
           } = json_response(response, 200)

    assert github_id == user.github_id
    assert namespace_id == user.github_id
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

  test "GET /api/v3/user requires a bearer token", %{conn: conn} do
    assert %{"error" => "invalid_api_token"} =
             conn
             |> get(~p"/api/v3/user")
             |> json_response(401)
  end
end
