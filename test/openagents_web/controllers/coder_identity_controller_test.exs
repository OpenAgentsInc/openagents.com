defmodule OpenAgentsWeb.CoderIdentityControllerTest do
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

  test "returns the account identity and readable repository reach", %{conn: conn} do
    user = github_user("coder-identity", "octavia")

    {:ok, user} =
      Accounts.store_github_token(user, "github-token", GitHubOAuth.required_scopes())

    {:ok, _token, plaintext} =
      ApiTokens.create(user, %{name: "Coder MCP", scopes: ["chat:account"]})

    Req.Test.stub(__MODULE__, fn github_conn ->
      case github_conn.request_path do
        "/user/memberships/orgs" ->
          Req.Test.json(github_conn, [])

        "/user/repos" ->
          Req.Test.json(github_conn, [
            repository(user.github_id, "octavia/visible", true),
            repository(user.github_id + 1, "other/hidden", false)
          ])

        path ->
          raise "unexpected GitHub path: #{path}"
      end
    end)

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> get(~p"/api/v1/coder/identity")

    assert %{
             "github_id" => github_id,
             "login" => "octavia",
             "repositories" => ["https://github.com/octavia/visible.git"]
           } = json_response(response, 200)

    assert github_id == user.github_id
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

  test "requires the chat account scope", %{conn: conn} do
    assert %{"code" => "unauthenticated"} =
             conn
             |> get(~p"/api/v1/coder/identity")
             |> json_response(401)
  end

  test "rejects a malformed bearer token", %{conn: conn} do
    assert %{"code" => "unauthenticated"} =
             conn
             |> put_req_header("authorization", "Bearer not-a-token")
             |> get(~p"/api/v1/coder/identity")
             |> json_response(401)
  end

  test "rejects a token that lacks the chat account scope", %{conn: conn} do
    user = github_user("coder-identity-wrong-scope", "octavia-scope")
    {:ok, _token, plaintext} = ApiTokens.create(user, %{name: "No chat", scopes: ["forge:write"]})

    assert %{"code" => "unauthenticated"} =
             conn
             |> put_req_header("authorization", "Bearer " <> plaintext)
             |> get(~p"/api/v1/coder/identity")
             |> json_response(401)
  end

  test "rejects an expired token", %{conn: conn} do
    user = github_user("coder-identity-expired", "octavia-expired")

    {:ok, token, plaintext} =
      ApiTokens.create(user, %{name: "Expired", scopes: ["chat:account"], lifetime_days: 1})

    yesterday = DateTime.add(DateTime.utc_now(), -1, :day)

    token
    |> Ecto.Changeset.change(
      inserted_at: DateTime.add(yesterday, -1, :day),
      expires_at: yesterday
    )
    |> OpenAgents.Repo.update!()

    assert %{"code" => "unauthenticated"} =
             conn
             |> put_req_header("authorization", "Bearer " <> plaintext)
             |> get(~p"/api/v1/coder/identity")
             |> json_response(401)
  end

  defp repository(owner_id, full_name, readable?) do
    [owner, name] = String.split(full_name, "/")

    %{
      "id" => owner_id,
      "node_id" => "repo-node-#{owner_id}",
      "name" => name,
      "full_name" => full_name,
      "private" => true,
      "default_branch" => "main",
      "owner" => %{
        "id" => owner_id,
        "node_id" => "owner-node-#{owner_id}",
        "login" => owner,
        "avatar_url" => "https://avatars.example.test/#{owner_id}",
        "type" => "User"
      },
      "permissions" => %{"pull" => readable?}
    }
  end
end
