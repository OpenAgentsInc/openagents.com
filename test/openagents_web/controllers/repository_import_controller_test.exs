defmodule OpenAgentsWeb.RepositoryImportControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.{Accounts, ApiTokens, GitHubOAuth, Repo}

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

  test "POST /api/v1/user/repos/imports accepts one frozen GitHub snapshot", %{conn: conn} do
    user = github_user("repository-import-api", "octavia")
    assert {:ok, user} = store_repository_grant(user, "gho_import_fixture")
    main_sha = String.duplicate("a", 40)
    tag_sha = String.duplicate("b", 40)

    expect_import_source(user, main_sha, tag_sha)

    response =
      conn
      |> authorize(user)
      |> put_req_header("idempotency-key", "import-key-1")
      |> post(~p"/api/v1/user/repos/imports", %{
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
      |> get(~p"/api/v1/repository-imports/#{import_id}")

    assert json_response(status, 200)["import"]["id"] == import_id

    other_user = github_user("repository-import-other")

    assert conn
           |> authorize(other_user)
           |> get(~p"/api/v1/repository-imports/#{import_id}")
           |> json_response(404)
  end

  test "an import inherits the GitHub repository visibility when omitted", %{conn: conn} do
    user = github_user("repository-public-import-api", "octavia")
    assert {:ok, user} = store_repository_grant(user, "gho_public_import_fixture")
    main_sha = String.duplicate("c", 40)

    expect_import_source(user, main_sha, nil, false)

    response =
      conn
      |> authorize(user)
      |> put_req_header("idempotency-key", "public-import-key")
      |> post(~p"/api/v1/user/repos/imports", %{
        source: %{provider: "github", repository: "octavia/source-project"}
      })

    assert %{"private" => false, "visibility" => "public"} = json_response(response, 202)
  end

  test "organization creation requires an active GitHub administrator membership", %{conn: conn} do
    user = github_user("repository-org-api")
    assert {:ok, user} = store_repository_grant(user, "gho_org_fixture")

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
      |> post(~p"/api/v1/orgs/acme/repos", %{name: "org-project", private: false})

    assert %{
             "full_name" => "acme/org-project",
             "private" => false,
             "owner" => %{"login" => "acme", "type" => "Organization"}
           } = json_response(created, 202)
  end

  describe "an upstream mirror of a repository this account does not own" do
    test "a foreign public source is refused by name, and the refusal names the source", %{
      conn: conn
    } do
      user = github_user("repository-foreign-import", "octavia")
      assert {:ok, user} = store_repository_grant(user, "gho_foreign_fixture")

      expect_foreign_source(String.duplicate("d", 40), false, "MIT")

      response =
        conn
        |> authorize(user)
        |> put_req_header("idempotency-key", "foreign-import-key")
        |> post(~p"/api/v1/user/repos/imports", %{
          source: %{provider: "github", repository: "tobi/walgit"}
        })

      body = json_response(response, 403)

      assert body["code"] == "source_namespace_mismatch"
      # The source owner is what failed, so the message says so. The old
      # message named the destination namespace, which was this account's own.
      assert body["message"] =~ "tobi/walgit"
      assert body["message"] =~ "owned by another GitHub account"
      assert body["message"] =~ ~s("mirror": true)
      assert body["failed"] == %{"source" => "tobi/walgit", "destination" => "eligible"}
    end

    test "the same source is brought in as a mirror, and the response names the upstream", %{
      conn: conn
    } do
      user = github_user("repository-mirror-api", "octavia")
      assert {:ok, user} = store_repository_grant(user, "gho_mirror_fixture")
      main_sha = String.duplicate("e", 40)

      expect_foreign_source(main_sha, false, "MIT")

      response =
        conn
        |> authorize(user)
        |> put_req_header("idempotency-key", "mirror-key")
        |> post(~p"/api/v1/user/repos/imports", %{
          source: %{provider: "github", repository: "tobi/walgit"},
          mirror: true
        })

      assert %{
               "name" => "walgit",
               "mirror" => true,
               "visibility" => "public",
               "upstream" => %{
                 "url" => "https://github.com/tobi/walgit",
                 "license" => "MIT",
                 "direction" => "one_way",
                 "accepts_pushes" => false
               },
               "permissions" => permissions
             } = json_response(response, 202)

      # The Git plane refuses every push to a mirror, so no projection of it
      # may report a push permission its owner does not have.
      assert permissions["push"] == false
      assert permissions["admin"] == true
    end

    test "an upstream with no license records the absence rather than omitting it", %{conn: conn} do
      user = github_user("repository-unlicensed-mirror", "octavia")
      assert {:ok, user} = store_repository_grant(user, "gho_unlicensed_fixture")

      expect_foreign_source(String.duplicate("f", 40), false, nil)

      response =
        conn
        |> authorize(user)
        |> put_req_header("idempotency-key", "unlicensed-mirror-key")
        |> post(~p"/api/v1/user/repos/imports", %{
          source: %{provider: "github", repository: "tobi/walgit"},
          mirror: true
        })

      assert %{"upstream" => %{"license" => "none"}} = json_response(response, 202)
    end

    test "a private source cannot be mirrored", %{conn: conn} do
      user = github_user("repository-private-mirror", "octavia")
      assert {:ok, user} = store_repository_grant(user, "gho_private_mirror_fixture")

      expect_foreign_source(String.duplicate("1", 40), true, "MIT")

      response =
        conn
        |> authorize(user)
        |> put_req_header("idempotency-key", "private-mirror-key")
        |> post(~p"/api/v1/user/repos/imports", %{
          source: %{provider: "github", repository: "tobi/walgit"},
          mirror: true
        })

      assert %{"code" => "source_repository_not_public"} = json_response(response, 403)
    end

    test "an owned repository publishes the distinction too", %{conn: conn} do
      user = github_user("repository-owned-projection")

      response =
        conn
        |> authorize(user)
        |> put_req_header("idempotency-key", "owned-projection-key")
        |> post(~p"/api/v1/user/repos", %{name: "mine", private: false})

      assert %{"mirror" => false, "upstream" => nil} = json_response(response, 202)
    end
  end

  defp store_repository_grant(user, token) do
    Accounts.store_github_token(user, token, GitHubOAuth.required_scopes())
  end

  defp expect_foreign_source(main_sha, private?, license) do
    Req.Test.expect(__MODULE__, fn github_conn ->
      assert github_conn.request_path == "/repos/tobi/walgit"

      Req.Test.json(github_conn, %{
        "id" => 909,
        "node_id" => "R_909",
        "name" => "walgit",
        "full_name" => "tobi/walgit",
        "private" => private?,
        "default_branch" => "main",
        "license" => if(license, do: %{"spdx_id" => license, "key" => "mit"}),
        "owner" => %{
          "id" => 777_777,
          "node_id" => "U_777777",
          "login" => "tobi",
          "avatar_url" => "https://avatars.githubusercontent.com/u/777777?v=4",
          "type" => "User"
        },
        "permissions" => %{"pull" => true, "push" => false, "admin" => false}
      })
    end)

    Req.Test.expect(__MODULE__, fn github_conn ->
      assert github_conn.request_path == "/repos/tobi/walgit/git/matching-refs/heads/"

      Req.Test.json(github_conn, [
        %{"ref" => "refs/heads/main", "object" => %{"type" => "commit", "sha" => main_sha}}
      ])
    end)

    Req.Test.expect(__MODULE__, fn github_conn ->
      assert github_conn.request_path == "/repos/tobi/walgit/git/matching-refs/tags/"
      Req.Test.json(github_conn, [])
    end)

    Req.Test.expect(__MODULE__, fn github_conn ->
      assert github_conn.request_path == "/repos/tobi/walgit/git/trees/main"

      Req.Test.json(github_conn, %{
        "truncated" => false,
        "tree" => [%{"path" => "README.md", "type" => "blob", "size" => 200}]
      })
    end)
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
