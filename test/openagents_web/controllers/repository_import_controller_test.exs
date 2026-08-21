defmodule OpenAgentsWeb.RepositoryImportControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.{Accounts, ApiTokens, Repo}

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

  test "POST /api/v3/user/repos/imports accepts one frozen GitHub snapshot", %{conn: conn} do
    user = github_user("repository-import-api", "octavia")
    assert {:ok, user} = Accounts.store_github_token(user, "gho_import_fixture")
    main_sha = String.duplicate("a", 40)
    tag_sha = String.duplicate("b", 40)

    expect_import_source(user, main_sha, tag_sha)

    response =
      conn
      |> authorize(user)
      |> put_req_header("idempotency-key", "import-key-1")
      |> post(~p"/api/v3/user/repos/imports", %{
        source: %{provider: "github", repository: "octavia/source-project"},
        name: "copied-project",
        private: true
      })

    assert %{
             "name" => "copied-project",
             "lifecycle_state" => "provisioning",
             "import" => %{
               "id" => import_id,
               "provider" => "github",
               "source_full_name" => "octavia/source-project",
               "source_head_sha" => ^main_sha,
               "state" => "pending",
               "lfs_warning" => true
             }
           } = json_response(response, 202)

    repository_import = Repo.get!(OpenAgents.Repositories.RepositoryImport, import_id)

    assert repository_import.source_refs == %{
             "refs/heads/main" => main_sha,
             "refs/tags/v1.0.0" => tag_sha
           }

    refute Map.has_key?(repository_import.source_refs, "credential")

    status =
      conn
      |> authorize(user)
      |> get(~p"/api/v3/repository-imports/#{import_id}")

    assert json_response(status, 200)["import"]["id"] == import_id

    other_user = github_user("repository-import-other")

    assert conn
           |> authorize(other_user)
           |> get(~p"/api/v3/repository-imports/#{import_id}")
           |> json_response(404)
  end

  test "an import inherits the GitHub repository visibility when omitted", %{conn: conn} do
    user = github_user("repository-public-import-api", "octavia")
    assert {:ok, user} = Accounts.store_github_token(user, "gho_public_import_fixture")
    main_sha = String.duplicate("c", 40)

    expect_import_source(user, main_sha, nil, false)

    response =
      conn
      |> authorize(user)
      |> put_req_header("idempotency-key", "public-import-key")
      |> post(~p"/api/v3/user/repos/imports", %{
        source: %{provider: "github", repository: "octavia/source-project"}
      })

    assert %{"private" => false, "visibility" => "public"} = json_response(response, 202)
  end

  test "organization creation requires an active GitHub administrator membership", %{conn: conn} do
    user = github_user("repository-org-api")
    assert {:ok, user} = Accounts.store_github_token(user, "gho_org_fixture")

    Req.Test.expect(__MODULE__, fn github_conn ->
      assert github_conn.request_path == "/user/memberships/orgs"

      Req.Test.json(github_conn, [
        %{
          "state" => "active",
          "role" => "admin",
          "organization" => %{
            "id" => 42,
            "node_id" => "O_42",
            "login" => "acme",
            "avatar_url" => "https://avatars.githubusercontent.com/u/42?v=4"
          }
        }
      ])
    end)

    created =
      conn
      |> authorize(user)
      |> put_req_header("idempotency-key", "org-create-key")
      |> post(~p"/api/v3/orgs/acme/repos", %{name: "org-project", private: false})

    assert %{
             "full_name" => "acme/org-project",
             "private" => false,
             "owner" => %{"login" => "acme", "type" => "Organization"}
           } = json_response(created, 202)
  end

  defp expect_import_source(user, main_sha, tag_sha, private? \\ true) do
    Req.Test.expect(__MODULE__, fn github_conn ->
      assert github_conn.request_path == "/repos/octavia/source-project"

      Req.Test.json(github_conn, %{
        "id" => 501,
        "node_id" => "R_501",
        "name" => "source-project",
        "full_name" => "octavia/source-project",
        "private" => private?,
        "default_branch" => "main",
        "owner" => %{
          "id" => user.github_id,
          "node_id" => "U_#{user.github_id}",
          "login" => "octavia",
          "avatar_url" => "https://avatars.githubusercontent.com/u/#{user.github_id}?v=4",
          "type" => "User"
        },
        "permissions" => %{"pull" => true, "push" => false, "admin" => false}
      })
    end)

    Req.Test.expect(__MODULE__, fn github_conn ->
      assert github_conn.request_path ==
               "/repos/octavia/source-project/git/matching-refs/heads/"

      Req.Test.json(github_conn, [
        %{"ref" => "refs/heads/main", "object" => %{"type" => "commit", "sha" => main_sha}}
      ])
    end)

    Req.Test.expect(__MODULE__, fn github_conn ->
      assert github_conn.request_path ==
               "/repos/octavia/source-project/git/matching-refs/tags/"

      tags =
        if tag_sha,
          do: [%{"ref" => "refs/tags/v1.0.0", "object" => %{"type" => "tag", "sha" => tag_sha}}],
          else: []

      Req.Test.json(github_conn, tags)
    end)

    Req.Test.expect(__MODULE__, fn github_conn ->
      assert github_conn.request_path == "/repos/octavia/source-project/git/trees/main"

      Req.Test.json(github_conn, %{
        "truncated" => false,
        "tree" => [%{"path" => ".gitattributes", "type" => "blob", "size" => 200}]
      })
    end)
  end

  defp authorize(conn, user) do
    {:ok, _credential, plaintext} =
      ApiTokens.create(user, %{name: "repository import API test", scopes: ["forge:write"]})

    put_req_header(conn, "authorization", "Bearer " <> plaintext)
  end
end
