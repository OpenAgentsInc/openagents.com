defmodule OpenAgentsWeb.RepositoryLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.{Accounts, Repo, Repositories}
  alias OpenAgents.Repositories.{ProvisioningOutbox, RepositoryImport}

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

  test "repository index loads bounded pages", %{conn: conn} do
    user = github_user("repository-live-pagination", "pagination-owner")

    Enum.each(1..21, fn number ->
      assert {:ok, _repository, :created} =
               Repositories.create_user_repository(
                 user,
                 %{name: "paged-#{String.pad_leading(to_string(number), 2, "0")}"},
                 "pagination-#{number}"
               )
    end)

    {:ok, view, _html} = live(log_in(conn, user), ~p"/repositories")
    last_repository = Repositories.get_by_path!("pagination-owner", "paged-21")

    assert has_element?(view, "#repositories-load-more")
    assert has_element?(view, "#repositories")
    refute has_element?(view, "#repositories-#{last_repository.id}")

    view |> element("#repositories-load-more") |> render_click()

    assert has_element?(view, "#repositories-#{last_repository.id}")
    refute has_element?(view, "#repositories-load-more")
  end

  test "the application sidebar reaches the repository index", %{conn: conn} do
    user = github_user("repository-live-sidebar", "sidebar-owner")
    {:ok, view, _html} = live(log_in(conn, user), ~p"/repositories")

    assert has_element?(view, ~s(#sidebar .sidebar-nav a[href="/repositories"]))
  end

  test "the index states one-time GitHub provenance and the current stage", %{conn: conn} do
    user = github_user("repository-live-provenance", "provenance-owner")

    assert {:ok, repository, :created} =
             Repositories.create_user_repository(
               user,
               %{name: "copied-project"},
               "provenance-copied"
             )

    github_import!(repository, %{state: "running", attempt_count: 1})
    claim_outbox!(repository)

    {:ok, view, _html} = live(log_in(conn, user), ~p"/repositories")

    row = "#repositories-#{repository.id}"

    assert has_element?(view, ~s(#{row}-provenance[data-source="acme/source-project"]))
    assert has_element?(view, ~s(#{row}-stage[data-state="running"]))
    assert render(view) =~ "Copying the GitHub snapshot"

    # REPOSITORY-001: never labelled as kept in step with the source.
    refute render(view) =~ "mirror"
    refute render(view) =~ "Synced"
  end

  test "the index names the error code of a failed repository", %{conn: conn} do
    user = github_user("repository-live-failure", "failure-owner")

    assert {:ok, repository, :created} =
             Repositories.create_user_repository(
               user,
               %{name: "broken-project"},
               "failure-broken"
             )

    repository
    |> Ecto.Changeset.change(
      lifecycle_state: "failed",
      provision_error_code: "provisioning_failed"
    )
    |> Repo.update!()

    {:ok, view, _html} = live(log_in(conn, user), ~p"/repositories")

    assert has_element?(view, ~s(#repositories-#{repository.id}-stage[data-state="failed"]))
    assert render(view) =~ "provisioning_failed"
  end

  test "the index follows a repository to ready without a reload", %{conn: conn} do
    user = github_user("repository-live-progress", "progress-owner")

    assert {:ok, repository, :created} =
             Repositories.create_user_repository(
               user,
               %{name: "watched-project"},
               "progress-watched"
             )

    {:ok, view, _html} = live(log_in(conn, user), ~p"/repositories")

    assert has_element?(view, ~s(#repositories-#{repository.id}-stage[data-state="running"]))

    repository
    |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
    |> Repo.update!()

    :ok = Repositories.broadcast_provisioning(repository.id)

    refute has_element?(view, "#repositories-#{repository.id}-stage")
    assert has_element?(view, "#repositories-#{repository.id}")
  end

  test "the index offers the real CLI commands", %{conn: conn} do
    user = github_user("repository-live-cli", "cli-owner")
    {:ok, view, html} = live(log_in(conn, user), ~p"/repositories")

    assert has_element?(view, "#repository-cli")
    assert has_element?(view, "#repository-cli-copy-0")
    assert has_element?(view, ~s(a[href="/docs/openagents-cli"]))
    assert html =~ "npx --yes @openagentsinc/cli@latest --version"
    assert html =~ "npm i -g @openagentsinc/cli"
    assert html =~ "openagents auth login"
    assert html =~ "openagents auth setup-git --local"
    assert html =~ "/&lt;owner&gt;/&lt;name&gt;.git"
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

  # A repository copied from GitHub, written through the same receipts the
  # importer writes, so the index reads the durable rows rather than a fixture
  # shape that only exists in tests.
  defp github_import!(repository, transition) do
    head = String.duplicate("b", 40)

    repository
    |> Ecto.Changeset.change(provisioning_kind: "github_import")
    |> Repo.update!()

    %RepositoryImport{}
    |> RepositoryImport.changeset(repository.id, %{
      source_repository_id: 4242,
      source_owner_id: 99,
      source_full_name: "acme/source-project",
      source_default_branch: "main",
      source_ref_digest: String.duplicate("a", 64),
      source_head_sha: head,
      source_refs: %{"refs/heads/main" => head}
    })
    |> Repo.insert!()
    |> RepositoryImport.transition_changeset(transition)
    |> Repo.update!()
  end

  defp claim_outbox!(repository) do
    now = DateTime.utc_now()

    ProvisioningOutbox
    |> Repo.get_by!(repository_id: repository.id)
    |> Ecto.Changeset.change(
      operation: "github_import",
      state: "running",
      attempt_count: 1,
      claimed_at: now
    )
    |> Repo.update!()
  end

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
