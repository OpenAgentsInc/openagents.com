defmodule OpenAgentsWeb.CodeLiveTest do
  @moduledoc """
  The public forge web UI (#136/#137, TRANSPARENCY-001): the repo home,
  the blob view (markdown rendered, ?plain=1 source, sha-pinned permanence),
  and the commit view with provenance trailers, diff, and the deploy story
  joined from the receipt chain. All anonymous; a dark or unknown repo, a
  missing path, and a flag-shaped ref 404 indistinguishably.
  """

  use OpenAgentsWeb.SarahConnCase, async: false
  @moduletag :skip
  import Phoenix.LiveViewTest

  alias OpenAgents.Forge.{DeployReceipt, Repos}
  alias OpenAgents.Repo

  @audit_heading "Transparency audit fixture"

  @second_message """
  Add the transparency audit fixture

  Changelog: Added the audit fixture
  Changelog-Category: docs
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_test
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
    Application.put_env(:openagents, :forge_public_visibility, %{"sarah" => :l2})
    Application.put_env(:openagents, :forge_public_paths, %{"sarah" => ["docs/audit.md"]})

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

    seed_repo("sarah")
  end

  defp browsable,
    do: Application.put_env(:openagents, :forge_public_visibility, %{"sarah" => :l3})

  # Two chained commits: the first seeds README.md + file.txt, the second
  # adds docs/audit.md (a markdown heading the tests can recognize) with the
  # provenance trailers in its message.
  defp seed_repo(repo) do
    path = Repos.ensure_repo!(repo)

    readme = write_blob(path, "# Sarah test repo\n\nFixture readme.\n")
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
        repo: "sarah",
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
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn -> live(conn, "/OpenAgentsInc/sarah") end
    end

    test "renders the repo home for a visitor with no session", %{conn: conn, short: short} do
      browsable()
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/sarah")

      assert html =~ "<h1>OpenAgentsInc/sarah</h1>"
      assert html =~ "Add the transparency audit fixture"
      assert html =~ "First commit"
      assert html =~ ~s(id="repo-refs")
      assert html =~ "main"
      assert html =~ short
      assert html =~ ~s(id="repo-readme")
      assert html =~ "Fixture readme."
    end

    test "publishes no node internals and no account controls anonymously", %{conn: conn} do
      browsable()
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/sarah")

      refute html =~ to_string(node())
      refute html =~ ~s(id="account-menu-trigger")
    end

    test "the repo is reachable only under its owning account", %{conn: conn} do
      browsable()
      # The GitHub-identical URL works...
      {:ok, _view, _html} = live(conn, "/OpenAgentsInc/sarah")
      # ...and no other account segment is even routed (no wildcard owner), so
      # a two-segment path that is not ours 404s without reaching a LiveView.
      assert conn |> get("/someoneelse/sarah") |> Map.fetch!(:status) == 404
      # The old /code/* shape is gone.
      assert conn |> get("/code/sarah") |> Map.fetch!(:status) == 404
    end

    test "a dark repo and an unknown repo 404 indistinguishably", %{conn: conn} do
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn -> live(conn, "/OpenAgentsInc/demo") end
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn -> live(conn, "/OpenAgentsInc/nope") end
    end
  end

  describe "/code/:repo/blob/:ref/*path" do
    test "renders markdown as HTML, not source", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/sarah/blob/main/docs/audit.md")

      assert html =~ @audit_heading
      refute html =~ "# #{@audit_heading}"
      assert html =~ ~s(class="code-markdown")
    end

    test "?plain=1 renders the raw markdown source", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/sarah/blob/main/docs/audit.md?plain=1")

      assert html =~ "# #{@audit_heading}"
      assert html =~ ~s(class="code-source")
    end

    test "a sha-pinned URL renders the same content when the repo is browsable", %{
      conn: conn,
      short: short
    } do
      browsable()
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/sarah/blob/#{short}/docs/audit.md")

      assert html =~ @audit_heading
      refute html =~ "# #{@audit_heading}"
    end

    test "a published document is served at head but NOT at an older ref", %{
      conn: conn,
      first: first,
      second: second
    } do
      # Head: served (it is on the allowlist).
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/sarah/blob/main/docs/audit.md")
      assert html =~ @audit_heading

      # The same path pinned to an older commit: 404. Publishing one document
      # must not publish every past revision of it.
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/OpenAgentsInc/sarah/blob/#{first}/docs/audit.md")
      end

      # Pinning to the head sha itself is fine — it is the same content.
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/sarah/blob/#{second}/docs/audit.md")
      assert html =~ @audit_heading
    end

    test "a path that is not on the published allowlist 404s below :l3", %{conn: conn} do
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/OpenAgentsInc/sarah/blob/main/README.md")
      end

      # …and is served once the repo is browsable.
      browsable()
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/sarah/blob/main/README.md")
      assert html =~ "Fixture readme."
    end

    test "a missing path 404s", %{conn: conn} do
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/OpenAgentsInc/sarah/blob/main/missing.txt")
      end
    end

    test "a flag-shaped ref 404s without reaching git", %{conn: conn} do
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/OpenAgentsInc/sarah/blob/-evil/file.txt")
      end
    end
  end

  describe "/code/:repo/commit/:sha" do
    test "renders subject, trailers, and changed files — but no diff below :l3", %{
      conn: conn,
      short: short
    } do
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/sarah/commit/#{short}")

      assert html =~ "Add the transparency audit fixture"
      assert html =~ "Claude-Session"
      assert html =~ "https://claude.ai/code/session_test"
      assert html =~ "docs/audit.md"

      # The ledger level publishes that a file changed, never its contents.
      refute html =~ "diff --git"
      refute html =~ @audit_heading
    end

    test "the diff is published once the repo is browsable", %{conn: conn, short: short} do
      browsable()
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/sarah/commit/#{short}")

      assert html =~ "diff --git"
      assert html =~ @audit_heading
    end

    test "a commit with no receipts says so honestly", %{conn: conn, short: short} do
      {:ok, _view, html} = live(conn, "/OpenAgentsInc/sarah/commit/#{short}")

      assert html =~ "Not deployed through the forge lane"
      refute html =~ "push→live"
    end

    test "a deploy receipt completes the deploy story", %{
      conn: conn,
      second: second,
      short: short
    } do
      insert_deploy!(second)

      {:ok, view, html} = live(conn, "/OpenAgentsInc/sarah/commit/#{short}")

      refute html =~ "Not deployed through the forge lane"

      story = view |> element("#commit-deploy-story") |> render()
      assert story =~ "deployed"
      assert story =~ "live"
      assert story =~ "push→live 5.5 s"
      assert story =~ "1 module on 3 nodes"
    end

    test "an unknown sha 404s", %{conn: conn} do
      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, "/OpenAgentsInc/sarah/commit/deadbeefdead")
      end
    end
  end
end
