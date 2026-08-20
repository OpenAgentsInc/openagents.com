defmodule OpenAgentsWeb.AdminForgeLiveTest do
  @moduledoc """
  `/admin/forge` carries the one write ADMIN-001 (as amended 2026-08-18)
  permits on the operator surface: promoting a pushed commit as the fleet
  target. The gate is the same as `/admin`; the write is receipted with the
  operator identity; only WAL-pushed SHAs are promotable.
  """

  use OpenAgentsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Forge.{Repos, Targets}

  setup do
    base = Path.join(System.tmp_dir!(), "forge-admin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    on_exit(fn ->
      Application.put_env(:openagents, :forge_data_dir, previous_data)
      Application.put_env(:openagents, :forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    :ok
  end

  defp seeded_commit(repo) do
    path = Repos.ensure_repo!(repo)
    {blob, 0} = plumb(path, ["hash-object", "-w", "--stdin"], "content\n")
    {tree, 0} = plumb(path, ["mktree"], "100644 blob #{String.trim(blob)}\tf.txt\n")

    {commit, 0} =
      plumb(path, ["commit-tree", String.trim(tree), "-m", "seed"], "",
        env: [
          {"GIT_AUTHOR_NAME", "t"},
          {"GIT_AUTHOR_EMAIL", "t@t"},
          {"GIT_COMMITTER_NAME", "t"},
          {"GIT_COMMITTER_EMAIL", "t@t"}
        ]
      )

    sha = String.trim(commit)
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", sha])
    sha
  end

  defp plumb(path, args, stdin, opts \\ []) do
    input = Path.join(System.tmp_dir!(), "plumb-#{System.unique_integer([:positive])}")
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

  test "the operator reaches the panel; ordinary and anonymous visitors do not", %{conn: conn} do
    admin = log_in_admin_user(conn, "forge-operator")
    {:ok, _view, html} = live(admin, ~p"/admin/forge")
    assert html =~ "Forge"

    ordinary = log_in_github_user(conn, "forge-ordinary")
    assert {:error, {:redirect, %{to: "/"}}} = live(ordinary, ~p"/admin/forge")
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/forge")
  end

  test "promote records the operator identity and broadcasts", %{conn: conn} do
    # "openagents.com" is the primary configured repo in test config.
    sha = seeded_commit("openagents.com")
    Phoenix.PubSub.subscribe(OpenAgents.PubSub, "forge:target")

    conn = log_in_admin_user(conn, "forge-promoter")
    {:ok, view, _html} = live(conn, ~p"/admin/forge")

    render_hook(view, "promote", %{"sha" => sha})

    assert_receive {:forge_target, %{repo: "openagents.com", sha: ^sha}}
    target = Targets.current("openagents.com")
    assert target.sha == sha
    assert target.promoted_by =~ "operator:"
    assert render(view) =~ String.slice(sha, 0, 12)
  end

  test "promoting a commit that is not in the forge is refused honestly", %{conn: conn} do
    Repos.ensure_repo!("openagents.com")
    conn = log_in_admin_user(conn, "forge-refuser")
    {:ok, view, _html} = live(conn, ~p"/admin/forge")

    refused_sha = String.duplicate("b", 40)
    render_hook(view, "promote", %{"sha" => refused_sha})

    # The refusal must create no target for THIS sha. (Not `current == nil`:
    # targets written by another test's async builder can leak past the
    # sandbox and land in the table, which made the global-emptiness form
    # flaky under the full suite.)
    refute Enum.any?(Targets.recent("openagents.com", 50), &(&1.sha == refused_sha))
    assert render(view) =~ "only pushed commits are promotable"
  end
end
