defmodule OpenAgentsWeb.RepositoryLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.{Accounts, Repo, Repositories}
  alias OpenAgents.Repositories.RepositoryImport

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

  test "repository index uses a scoped stream and shows lifecycle state", %{conn: conn} do
    user = github_user("repository-live-index", "index-owner")

    assert {:ok, repository, :created} =
             Repositories.create_user_repository(
               user,
               %{name: "streamed-repository", visibility: "private"},
               "streamed-repository"
             )

    {:ok, view, _html} = live(log_in(conn, user), ~p"/repositories")

    assert has_element?(view, "#repository-index")
    assert has_element?(view, "#repositories-#{repository.id}")
    assert has_element?(view, "#new-repository")
    assert has_element?(view, "#import-repository")
  end

  test "new repository defaults private and normalizes its name", %{conn: conn} do
    user = github_user("repository-live-create", "create-owner")
    {:ok, view, _html} = live(log_in(conn, user), ~p"/repositories/new")

    assert has_element?(view, "#repository-form")
    assert has_element?(view, "#repository_private[type=checkbox]")

    view
    |> form("#repository-form", %{
      "repository" => %{
        "namespace" => "create-owner",
        "name" => "My.Project",
        "description" => "Created in the browser",
        "default_branch" => "trunk",
        "private" => "true"
      }
    })
    |> render_submit()

    assert_redirect(view, ~p"/repositories")

    repository = Repositories.get_by_path!("create-owner", "my.project")
    assert repository.name == "my.project"
    assert repository.visibility == "private"
    assert repository.default_branch == "trunk"
    assert repository.lifecycle_state == "provisioning"
  end

  test "one-time import picker creates an immutable GitHub import receipt", %{conn: conn} do
    user = github_user("repository-live-import", "import-owner")
    assert {:ok, user} = Accounts.store_github_token(user, "gho_live_import")
    main_sha = String.duplicate("a", 40)

    Req.Test.stub(__MODULE__, &github_import_response(&1, user, main_sha))

    {:ok, view, _html} = live(log_in(conn, user), ~p"/repositories/import/github")

    assert has_element?(view, "#one-time-import")
    assert has_element?(view, "#repository-import-form")
    assert has_element?(view, "#lfs-import-warning")

    view
    |> form("#repository-import-form", %{
      "repository_import" => %{
        "source" => "import-owner/source-project",
        "name" => "copied-project",
        "private" => "true"
      }
    })
    |> render_submit()

    assert_redirect(view, ~p"/repositories")
    repository = Repositories.get_by_path!("import-owner", "copied-project")
    repository_import = Repo.get_by!(RepositoryImport, repository_id: repository.id)

    assert repository.provisioning_kind == "github_import"
    assert repository_import.source_full_name == "import-owner/source-project"
    assert repository_import.source_head_sha == main_sha
    assert repository_import.source_refs == %{"refs/heads/main" => main_sha}
  end

  defp log_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp repository_payload(user, main_sha) do
    %{
      "id" => 901,
      "node_id" => "R_901",
      "name" => "source-project",
      "full_name" => "import-owner/source-project",
      "private" => true,
      "fork" => false,
      "archived" => false,
      "default_branch" => "main",
      "description" => "Source repository",
      "language" => "Elixir",
      "pushed_at" => "2026-08-20T12:00:00Z",
      "size" => 20,
      "owner" => %{
        "id" => user.github_id,
        "node_id" => "U_#{user.github_id}",
        "login" => "import-owner",
        "avatar_url" => "https://avatars.githubusercontent.com/u/#{user.github_id}?v=4",
        "type" => "User"
      },
      "permissions" => %{"pull" => true, "push" => true, "admin" => true},
      "sha" => main_sha
    }
  end

  defp github_import_response(github_conn, user, main_sha) do
    case github_conn.request_path do
      "/user/memberships/orgs" ->
        Req.Test.json(github_conn, [])

      "/user/repos" ->
        Req.Test.json(github_conn, [repository_payload(user, main_sha)])

      "/repos/import-owner/source-project" ->
        Req.Test.json(github_conn, repository_payload(user, main_sha))

      "/repos/import-owner/source-project/git/matching-refs/heads/" ->
        Req.Test.json(github_conn, [
          %{"ref" => "refs/heads/main", "object" => %{"type" => "commit", "sha" => main_sha}}
        ])

      "/repos/import-owner/source-project/git/matching-refs/tags/" ->
        Req.Test.json(github_conn, [])

      "/repos/import-owner/source-project/git/trees/main" ->
        Req.Test.json(github_conn, %{"truncated" => false, "tree" => []})
    end
  end
end
