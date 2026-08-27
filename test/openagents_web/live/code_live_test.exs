defmodule OpenAgentsWeb.CodeLiveTest do
  @moduledoc """
  The public forge web UI (#136/#137, TRANSPARENCY-001): the repo home,
  the blob view (markdown rendered, ?plain=1 source, sha-pinned permanence),
  and the commit view with provenance trailers, diff, and the deploy story
  joined from the receipt chain. All anonymous; a dark or unknown repo, a
  missing path, and a flag-shaped ref 404 indistinguishably.
  """

  use OpenAgentsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Forge.{DeployReceipt, Repos}
  alias OpenAgents.Forge.WAL.Probe
  alias OpenAgents.Repo

  @audit_heading "Transparency audit fixture"

  @second_message """
  Add the transparency audit fixture

  Changelog: Added the audit fixture
  Changelog-Category: docs
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_test
  Closes #4242
  """

  setup do
    base = Path.join(System.tmp_dir!(), "code-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    # The production posture: a PRIVATE repo at :l2 that publishes one
    # document by path. Tests that need source browsing raise the level
    # explicitly via `browsable/0`.
    previous_vis = Application.get_env(:openagents, :forge_public_visibility)
    previous_paths = Application.get_env(:openagents, :forge_public_paths)
    Application.put_env(:openagents, :forge_public_visibility, %{"openagents.com" => :l2})

    Application.put_env(:openagents, :forge_public_paths, %{"openagents.com" => ["docs/audit.md"]})

    on_exit(fn ->
      if previous_data,
        do: Application.put_env(:openagents, :forge_data_dir, previous_data),
        else: Application.delete_env(:openagents, :forge_data_dir)

      if previous_wal,
        do: Application.put_env(:openagents, :forge_wal_dir, previous_wal),
        else: Application.delete_env(:openagents, :forge_wal_dir)

      if previous_vis,
        do: Application.put_env(:openagents, :forge_public_visibility, previous_vis),
        else: Application.delete_env(:openagents, :forge_public_visibility)

      if previous_paths,
        do: Application.put_env(:openagents, :forge_public_paths, previous_paths),
        else: Application.delete_env(:openagents, :forge_public_paths)

      File.rm_rf(base)
    end)

    seed_repo("openagents.com")
  end

  defp browsable,
    do: Application.put_env(:openagents, :forge_public_visibility, %{"openagents.com" => :l3})

  # Two chained commits: the first seeds README.md + file.txt, the second
  # adds docs/audit.md (a markdown heading the tests can recognize) with the
  # provenance trailers in its message.
  defp seed_repo(repo) do
    path = Repos.ensure_repo!(repo)

    # The trailing paragraph is wrapped the way a file is wrapped, so a test can
    # tell a rendered document from one line break per source line.
    readme =
      write_blob(
        path,
        "# OpenAgents test repo\n\nFixture readme.\n\n" <>
          "This paragraph is wrapped like a file\nrather than like a message.\n"
      )

    file = write_blob(path, "hello\n")

    tree_one =
      mktree(path, "100644 blob #{readme}\tREADME.md\n100644 blob #{file}\tfile.txt\n")

    first = commit_tree(path, tree_one, [], "First commit\n")

    audit = write_blob(path, "# #{@audit_heading}\n\nBody of the audit note.\n")
    docs_tree = mktree(path, "100644 blob #{audit}\taudit.md\n")

    tree_two =
      mktree(
        path,
        "100644 blob #{readme}\tREADME.md\n" <>
          "040000 tree #{docs_tree}\tdocs\n" <>
          "100644 blob #{file}\tfile.txt\n"
      )

    second = commit_tree(path, tree_two, ["-p", first], @second_message)

    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", second])
    %{first: first, second: second, short: String.slice(second, 0, 12)}
  end

  defp write_blob(path, content) do
    {sha, 0} = git_in(path, ["hash-object", "-w", "--stdin"], content)
    String.trim(sha)
  end

  defp mktree(path, listing) do
    {sha, 0} = git_in(path, ["mktree"], listing)
    String.trim(sha)
  end

  defp commit_tree(path, tree, parent_args, message) do
    {sha, 0} =
      git_in(path, ["commit-tree", tree] ++ parent_args, message,
        env: [
          {"GIT_AUTHOR_NAME", "Test Author"},
          {"GIT_AUTHOR_EMAIL", "author@example.test"},
          {"GIT_COMMITTER_NAME", "Test Author"},
          {"GIT_COMMITTER_EMAIL", "author@example.test"}
        ]
      )

    String.trim(sha)
  end

  defp git_in(path, args, stdin, opts \\ []) do
    input = Path.join(System.tmp_dir!(), "code-live-stdin-#{System.unique_integer([:positive])}")
    File.write!(input, stdin)

    try do
      System.cmd(
        "sh",
        ["-c", ~s(exec git --git-dir "$GD" "$@" < "$IN"), "sh"] ++ args,
        env: [{"GD", path}, {"IN", input}] ++ Keyword.get(opts, :env, [])
      )
    after
      File.rm(input)
    end
  end

  defp insert_deploy!(sha) do
    {:ok, deploy} =
      %DeployReceipt{}
      |> DeployReceipt.changeset(%{
        repo: "openagents.com",
        sha: sha,
        target_id: Ecto.UUID.generate(),
        result: "live",
        modules: ["Elixir.OpenAgents.Something"],
        nodes: ["node-a", "node-b", "node-c"],
        push_to_live_ms: 5_540
      })
      |> Repo.insert()

    deploy
  end

  describe "/code/:repo" do
    test "a private repo below :l3 does not expose a browsable repo home", %{conn: conn} do
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/OpenAgentsInc/openagents.com")
      end
    end

    test "renders the repo home for a visitor with no session", %{conn: conn, short: short} do
      browsable()
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/openagents.com")

      # The identity is the owner trail of the composed repository view now,
      # not a bare heading.
      assert html =~ ~s(aria-label="OpenAgentsInc / openagents.com")
      assert html =~ ~s(class="repo-view)
      assert html =~ ~s(class="repo-tabs)
      assert html =~ ~s(class="mx-auto w-full space-y-4 max-w-none")
      assert html =~ "Add the transparency audit fixture"
      assert html =~ "First commit"
      assert html =~ ~s(id="repo-refs")
      assert html =~ "main"
      assert html =~ short
      assert html =~ ~s(id="repo-readme")
      assert html =~ "Fixture readme."
    end

    test "keeps configured source public after the storage key joins the forge", %{conn: conn} do
      repository =
        OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com")

      previous_repos = Application.fetch_env!(:openagents, :forge_repos)

      Application.put_env(
        :openagents,
        :forge_repos,
        Enum.uniq(previous_repos ++ [repository.storage_key])
      )

      on_exit(fn -> Application.put_env(:openagents, :forge_repos, previous_repos) end)

      browsable()
      {:ok, view, _html} = live(conn, "/OpenAgentsInc/openagents.com")

      assert has_element?(view, "#code-repo-page")
    end

    test "the repository nav separates issues from pull requests", %{conn: conn} do
      browsable()
      {:ok, view, _html} = live(conn, "/OpenAgentsInc/openagents.com")

      assert has_element?(view, "a[href='/OpenAgentsInc/openagents.com/issues']")
      assert has_element?(view, "a[href='/OpenAgentsInc/openagents.com/pulls']")

      assert has_element?(
               view,
               "a[href='/OpenAgentsInc/openagents.com/pulls'] [data-icon='pull-request-open']"
             )
    end

    test "the latest commit reads as how long ago, not as a calendar date", %{conn: conn} do
      browsable()
      {:ok, view, _html} = live(conn, "/OpenAgentsInc/openagents.com")

      # The fixture commits are written as the test runs, so a stamp that reads
      # in minutes is the proof #27 asked for: the coarse span, not `%Y-%m-%d`.
      stamp = view |> element(".file-table__commit time") |> render()

      assert stamp =~ ~r/\d+[mhd] ago/
      refute stamp =~ ~r/\d{4}-\d{2}-\d{2}</

      # Precision moved rather than disappeared.
      assert has_element?(view, ".file-table__commit time[datetime][title]")
    end

    test "every recent commit carries the same relative stamp", %{conn: conn} do
      browsable()
      {:ok, view, _html} = live(conn, "/OpenAgentsInc/openagents.com")

      assert has_element?(view, "#repo-commits time[datetime][title]")
      assert view |> element("#repo-commits li:first-child time") |> render() =~ ~r/\d+[mhd] ago/
    end

    test "renders the README as a formatted document", %{conn: conn} do
      browsable()
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/openagents.com")

      # Structure, not source: the heading is a heading, and it carries the
      # ruleset every rendered-Markdown surface shares.
      assert html =~ ~s(class="markdown")
      assert html =~ "<h1>OpenAgents test repo</h1>"

      # A file's own wrapping is not a line break. Hard breaks belong to typed
      # messages; here they would render the README at the width of its source.
      refute html =~ "wrapped like a file<br"
    end

    test "publishes no node internals and no account controls anonymously", %{conn: conn} do
      browsable()
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/openagents.com")

      refute html =~ to_string(node())
      refute html =~ ~s(id="account-menu-trigger")
    end

    test "the repo is reachable only under its owning account", %{conn: conn} do
      browsable()
      # The GitHub-identical URL works...
      {:ok, _view, _html} = live(conn, "/OpenAgentsInc/openagents.com")
      # ...and a different namespace reaches the database-backed resolver but
      # remains concealed as the same public not-found result.
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/someoneelse/demo")
      end

      # The old /code/* shape resolves as an unknown namespace and stays hidden.
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn -> live(conn, "/code/demo") end
    end

    test "a dark repo and an unknown repo 404 indistinguishably", %{conn: conn} do
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn -> live(conn, "/OpenAgentsInc/demo") end
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn -> live(conn, "/OpenAgentsInc/nope") end
    end
  end

  describe "database-backed hosted repository pages" do
    test "an empty ready public repository renders clone instructions", %{conn: conn} do
      user = github_user("empty-hosted-repository", "hosted-owner")

      assert {:ok, repository, :created} =
               OpenAgents.Repositories.create_user_repository(
                 user,
                 %{name: "empty-repository", visibility: "public", default_branch: "trunk"},
                 "empty-hosted-repository"
               )

      repository
      |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
      |> Repo.update!()

      Repos.ensure_repo!(repository.storage_key, "trunk")

      {:ok, view, _html} = live(conn, "/hosted-owner/empty-repository")

      assert has_element?(view, "#repo-empty")
      assert has_element?(view, "#repo-clone")
      refute has_element?(view, "#repo-commits")
    end

    test "a private repository is visible only to a member session", %{conn: conn} do
      owner = github_user("private-hosted-owner", "private-hosted-owner")
      outsider = github_user("private-hosted-outsider", "private-hosted-outsider")

      assert {:ok, repository, :created} =
               OpenAgents.Repositories.create_user_repository(
                 owner,
                 %{name: "private-repository", visibility: "private"},
                 "private-hosted-repository"
               )

      member_conn = Plug.Test.init_test_session(conn, %{"user_id" => owner.id})
      {:ok, view, _html} = live(member_conn, "/private-hosted-owner/private-repository")
      assert has_element?(view, "#repo-provisioning")

      outsider_conn = Plug.Test.init_test_session(recycle(conn), %{"user_id" => outsider.id})

      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(outsider_conn, "/private-hosted-owner/private-repository")
      end

      assert repository.lifecycle_state == "provisioning"
    end

    test "an imported repository states one-time GitHub provenance", %{conn: conn} do
      owner = github_user("import-provenance-owner", "import-provenance-owner")

      assert {:ok, repository, :created} =
               OpenAgents.Repositories.create_user_repository(
                 owner,
                 %{name: "copied-repository", visibility: "private"},
                 "import-provenance-repository"
               )

      head = String.duplicate("b", 40)

      repository
      |> Ecto.Changeset.change(provisioning_kind: "github_import")
      |> Repo.update!()

      %OpenAgents.Repositories.RepositoryImport{}
      |> OpenAgents.Repositories.RepositoryImport.changeset(repository.id, %{
        source_repository_id: 4242,
        source_owner_id: 99,
        source_full_name: "acme/source-project",
        source_default_branch: "main",
        source_ref_digest: String.duplicate("a", 64),
        source_head_sha: head,
        source_refs: %{"refs/heads/main" => head}
      })
      |> Repo.insert!()
      |> OpenAgents.Repositories.RepositoryImport.transition_changeset(%{
        state: "completed",
        attempt_count: 1,
        completed_at: DateTime.utc_now()
      })
      |> Repo.update!()

      member_conn = Plug.Test.init_test_session(conn, %{"user_id" => owner.id})
      {:ok, view, html} = live(member_conn, "/import-provenance-owner/copied-repository")

      assert has_element?(view, ".repo-view__rail #repo-import-provenance")
      assert html =~ "Imported from GitHub"
      assert html =~ "acme/source-project"
      assert html =~ String.slice(head, 0, 12)

      # REPOSITORY-001: OpenAgents owns the snapshot; nothing keeps it in step
      # with GitHub, so the page must never claim otherwise.
      refute html =~ "mirror"
      refute html =~ "Synced"
    end

    test "an upstream mirror names its upstream to an anonymous reader", %{conn: conn} do
      owner = github_user("mirror-page-owner", "mirror-page-owner")

      assert {:ok, repository, _import, :created} =
               OpenAgents.Repositories.create_user_mirror(
                 owner,
                 %{
                   source_repository_id: 909,
                   source_owner_id: 777_777,
                   source_full_name: "tobi/walgit",
                   source_default_branch: "main",
                   source_ref_digest: String.duplicate("a", 64),
                   source_head_sha: String.duplicate("c", 40),
                   source_refs: %{"refs/heads/main" => String.duplicate("c", 40)},
                   source_uses_lfs: false,
                   source_public: true,
                   source_license: "MIT"
                 },
                 %{name: "walgit", visibility: "public", default_branch: "main"},
                 "mirror-page-key"
               )

      repository
      |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
      |> Repo.update!()

      # No session: a stranger reading the page is the reader most likely to
      # mistake a mirror for something this account wrote.
      {:ok, view, html} = live(conn, "/mirror-page-owner/walgit")

      assert has_element?(view, ".repo-view__rail #repo-upstream-mirror")
      assert html =~ "Upstream mirror"
      assert html =~ "https://github.com/tobi/walgit"
      assert html =~ "MIT"
      assert html =~ "accepts no pushes"

      # The import block claims OpenAgents owns the snapshot. A mirror makes
      # the opposite claim, so the two never appear together.
      refute has_element?(view, "#repo-import-provenance")
      refute html =~ "Imported from GitHub"
    end

    test "a mirror of an unlicensed upstream says so rather than staying silent", %{conn: conn} do
      owner = github_user("unlicensed-mirror-page", "unlicensed-mirror-page")

      assert {:ok, repository, _import, :created} =
               OpenAgents.Repositories.create_user_mirror(
                 owner,
                 %{
                   source_repository_id: 910,
                   source_owner_id: 777_777,
                   source_full_name: "tobi/unlicensed",
                   source_default_branch: "main",
                   source_ref_digest: String.duplicate("a", 64),
                   source_head_sha: String.duplicate("c", 40),
                   source_refs: %{"refs/heads/main" => String.duplicate("c", 40)},
                   source_uses_lfs: false,
                   source_public: true,
                   source_license: nil
                 },
                 %{name: "unlicensed", visibility: "public", default_branch: "main"},
                 "unlicensed-mirror-page-key"
               )

      repository
      |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
      |> Repo.update!()

      {:ok, _view, html} = live(conn, "/unlicensed-mirror-page/unlicensed")

      assert html =~ "No license found upstream"
    end

    test "a repository created empty shows no import provenance", %{conn: conn} do
      owner = github_user("no-provenance-owner", "no-provenance-owner")

      assert {:ok, _repository, :created} =
               OpenAgents.Repositories.create_user_repository(
                 owner,
                 %{name: "plain-repository", visibility: "private"},
                 "no-provenance-repository"
               )

      member_conn = Plug.Test.init_test_session(conn, %{"user_id" => owner.id})
      {:ok, view, _html} = live(member_conn, "/no-provenance-owner/plain-repository")

      refute has_element?(view, "#repo-import-provenance")
    end

    test "an owner can delete a repository after typing its full name", %{conn: conn} do
      owner = github_user("delete-repository-owner", "delete-repository-owner")

      assert {:ok, repository, :created} =
               OpenAgents.Repositories.create_user_repository(
                 owner,
                 %{name: "delete-repository", visibility: "private"},
                 "delete-repository-ui"
               )

      member_conn = Plug.Test.init_test_session(conn, %{"user_id" => owner.id})
      {:ok, view, _html} = live(member_conn, "/delete-repository-owner/delete-repository")

      assert has_element?(view, "#repository-danger-zone")
      assert has_element?(view, "#repository-delete-form")

      view
      |> form("#repository-delete-form", %{
        "repository_delete" => %{"confirmation" => "wrong-name"}
      })
      |> render_submit()

      assert has_element?(view, "#repository-delete-error")

      result =
        view
        |> form("#repository-delete-form", %{
          "repository_delete" => %{
            "confirmation" => "delete-repository-owner/delete-repository"
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/repositories"}}} = result

      assert_raise Ecto.NoResultsError, fn ->
        OpenAgents.Repositories.get_by_path!("delete-repository-owner", "delete-repository")
      end

      refute File.exists?(Repos.bare_path(repository.storage_key))
    end

    test "a non-owner never sees repository deletion controls", %{conn: conn} do
      owner = github_user("delete-repository-control-owner", "delete-control-owner")
      viewer = github_user("delete-repository-control-viewer", "delete-control-viewer")

      assert {:ok, repository, :created} =
               OpenAgents.Repositories.create_user_repository(
                 owner,
                 %{name: "protected-repository", visibility: "private"},
                 "delete-repository-controls"
               )

      assert {:ok, _membership} = OpenAgents.Repositories.add_member(repository, viewer, "viewer")
      viewer_conn = Plug.Test.init_test_session(conn, %{"user_id" => viewer.id})
      {:ok, view, _html} = live(viewer_conn, "/delete-control-owner/protected-repository")

      refute has_element?(view, "#repository-danger-zone")
      refute has_element?(view, "#repository-delete-form")
    end

    test "an owner can update the pull request setting", %{conn: conn} do
      owner = github_user("pull-request-setting-owner", "pull-request-setting-owner")

      assert {:ok, _repository, :created} =
               OpenAgents.Repositories.create_user_repository(
                 owner,
                 %{name: "pull-request-setting", visibility: "private"},
                 "pull-request-setting-ui"
               )

      owner_conn = Plug.Test.init_test_session(conn, %{"user_id" => owner.id})
      {:ok, view, _html} = live(owner_conn, "/pull-request-setting-owner/pull-request-setting")

      assert has_element?(view, "#repository-pull-request-settings")
      assert has_element?(view, "#repository-pull-request-settings-form")

      view
      |> form("#repository-pull-request-settings-form", %{
        "repository" => %{"pull_requests_enabled" => "false"}
      })
      |> render_submit()

      repository =
        OpenAgents.Repositories.get_by_path!(
          "pull-request-setting-owner",
          "pull-request-setting"
        )

      refute repository.pull_requests_enabled
    end

    test "a non-owner never sees pull request settings", %{conn: conn} do
      owner = github_user("pull-request-control-owner", "pull-request-control-owner")
      viewer = github_user("pull-request-control-viewer", "pull-request-control-viewer")

      assert {:ok, repository, :created} =
               OpenAgents.Repositories.create_user_repository(
                 owner,
                 %{name: "pull-request-control", visibility: "private"},
                 "pull-request-setting-controls"
               )

      assert {:ok, _membership} = OpenAgents.Repositories.add_member(repository, viewer, "viewer")
      viewer_conn = Plug.Test.init_test_session(conn, %{"user_id" => viewer.id})
      {:ok, view, _html} = live(viewer_conn, "/pull-request-control-owner/pull-request-control")

      refute has_element?(view, "#repository-pull-request-settings")
      refute has_element?(view, "#repository-pull-request-settings-form")
    end
  end

  describe "/code/:repo/blob/:ref/*path" do
    test "performs one freshness barrier for a code blob request", %{conn: conn} do
      previous_adapter = Application.fetch_env!(:openagents, :forge_wal_adapter)
      previous_probe = Application.get_env(:openagents, :forge_wal_probe_pid)
      Application.put_env(:openagents, :forge_wal_adapter, Probe)
      Application.put_env(:openagents, :forge_wal_probe_pid, self())

      on_exit(fn ->
        Application.put_env(:openagents, :forge_wal_adapter, previous_adapter)

        if previous_probe,
          do: Application.put_env(:openagents, :forge_wal_probe_pid, previous_probe),
          else: Application.delete_env(:openagents, :forge_wal_probe_pid)
      end)

      conn = get(conn, "/OpenAgentsInc/openagents.com/blob/main/docs/audit.md")
      assert html_response(conn, 200)

      assert_receive {Probe, :read_index, "openagents.com"}
      refute_receive {Probe, :read_index, "openagents.com"}
    end

    test "renders markdown as HTML, not source", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/openagents.com/blob/main/docs/audit.md")

      assert html =~ @audit_heading
      refute html =~ "# #{@audit_heading}"
      assert html =~ ~s(class="markdown")
    end

    test "?plain=1 renders the raw markdown source", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, "/OpenAgentsInc/openagents.com/blob/main/docs/audit.md?plain=1")

      assert html =~ "# #{@audit_heading}"
      assert html =~ ~s(class="code-source")
    end

    test "a sha-pinned URL renders the same content when the repo is browsable", %{
      conn: conn,
      short: short
    } do
      browsable()
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/openagents.com/blob/#{short}/docs/audit.md")

      assert html =~ @audit_heading
      refute html =~ "# #{@audit_heading}"
    end

    test "a published document is served at head but NOT at an older ref", %{
      conn: conn,
      first: first,
      second: second
    } do
      # Head: served (it is on the allowlist).
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/openagents.com/blob/main/docs/audit.md")
      assert html =~ @audit_heading

      # The same path pinned to an older commit: 404. Publishing one document
      # must not publish every past revision of it.
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/OpenAgentsInc/openagents.com/blob/#{first}/docs/audit.md")
      end

      # Pinning to the head sha itself is fine — it is the same content.
      {:ok, _view, html} =
        live(conn, "/OpenAgentsInc/openagents.com/blob/#{second}/docs/audit.md")

      assert html =~ @audit_heading
    end

    test "a path that is not on the published allowlist 404s below :l3", %{conn: conn} do
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/OpenAgentsInc/openagents.com/blob/main/README.md")
      end

      # …and is served once the repo is browsable.
      browsable()
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/openagents.com/blob/main/README.md")
      assert html =~ "Fixture readme."
    end

    test "a missing path 404s", %{conn: conn} do
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/OpenAgentsInc/openagents.com/blob/main/missing.txt")
      end
    end

    test "a flag-shaped ref 404s without reaching git", %{conn: conn} do
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/OpenAgentsInc/openagents.com/blob/-evil/file.txt")
      end
    end
  end

  describe "/code/:repo/tree/:ref/*path" do
    test "renders a repository directory and links its children", %{conn: conn} do
      browsable()

      {:ok, view, _html} =
        live(conn, "/OpenAgentsInc/openagents.com/tree/main/docs")

      assert has_element?(view, "#code-tree-page")

      assert has_element?(
               view,
               ~s(a[href="/OpenAgentsInc/openagents.com/blob/main/docs/audit.md"])
             )
    end

    test "follows a directory link emitted by the repository home", %{conn: conn} do
      browsable()
      {:ok, home, _html} = live(conn, "/OpenAgentsInc/openagents.com")

      assert has_element?(
               home,
               ~s(a[href="/OpenAgentsInc/openagents.com/tree/main/docs"])
             )

      {:ok, tree, _html} =
        live(conn, "/OpenAgentsInc/openagents.com/tree/main/docs")

      assert has_element?(tree, ~s([data-kind="blob"]), "audit.md")
    end

    test "a directory remains concealed when the repository source is not browsable", %{
      conn: conn
    } do
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/OpenAgentsInc/openagents.com/tree/main/docs")
      end
    end

    test "a missing directory 404s", %{conn: conn} do
      browsable()

      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/OpenAgentsInc/openagents.com/tree/main/missing")
      end
    end
  end

  describe "/code/:repo/commit/:sha" do
    test "renders subject, trailers, and changed files — but no diff below :l3", %{
      conn: conn,
      short: short
    } do
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/openagents.com/commit/#{short}")

      assert html =~ "Add the transparency audit fixture"
      assert html =~ "Claude-Session"
      assert html =~ "https://claude.ai/code/session_test"
      assert html =~ "docs/audit.md"

      # The ledger level publishes that a file changed, never its contents.
      # The diff is parsed now, so the absence to assert is the rendered
      # component rather than git's header line, which no longer reaches the
      # page in either case.
      refute html =~ "diff-file"
      refute html =~ @audit_heading
    end

    test "the commit stamp reads relatively and keeps the exact moment", %{
      conn: conn,
      short: short
    } do
      {:ok, view, _html} = live(conn, "/OpenAgentsInc/openagents.com/commit/#{short}")

      assert has_element?(view, "#code-commit-page time[datetime][title]")
      assert view |> element("#code-commit-page time") |> render() =~ ~r/\d+[mhd] ago/
    end

    test "the diff is published once the repo is browsable", %{conn: conn, short: short} do
      browsable()
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/openagents.com/commit/#{short}")

      assert html =~ "diff-file"
      assert html =~ "diff-line"
      assert html =~ @audit_heading
    end

    test "a commit with no receipts says so honestly", %{conn: conn, short: short} do
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/openagents.com/commit/#{short}")

      assert html =~ "Not deployed through the forge lane"
      refute html =~ "push→live"
    end

    test "a deploy receipt completes the deploy story", %{
      conn: conn,
      second: second,
      short: short
    } do
      insert_deploy!(second)

      {:ok, view, html} = live(conn, "/OpenAgentsInc/openagents.com/commit/#{short}")

      refute html =~ "Not deployed through the forge lane"

      story = view |> element("#commit-deploy-story") |> render()
      assert story =~ "deployed"
      assert story =~ "live"
      assert story =~ "push→live 5.5 s"
      assert story =~ "1 module on 3 nodes"
    end

    test "an unknown sha 404s", %{conn: conn} do
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/OpenAgentsInc/openagents.com/commit/deadbeefdead")
      end
    end

    # #130: the page renders what the message says it closes, and links it.
    # The reference is read from the message, so the page says the same thing
    # whether or not the push path acted on it.
    test "the closing references the message carries are rendered and linked", %{
      conn: conn,
      short: short
    } do
      {:ok, view, html} = live(conn, "/OpenAgentsInc/openagents.com/commit/#{short}")

      assert html =~ "Closes"
      assert has_element?(view, "#commit-closing-references")

      assert has_element?(
               view,
               ~s{#commit-closing-references a[href="/OpenAgentsInc/openagents.com/issues/4242"]}
             )
    end
  end
end
