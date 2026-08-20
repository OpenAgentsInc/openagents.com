defmodule OpenAgents.Forge.SarahTargetsTest do
  use OpenAgents.SarahDataCase, async: false
  alias OpenAgents.Forge.{Repos, Targets}

  setup do
    base = Path.join(System.tmp_dir!(), "forge-targets-#{System.unique_integer([:positive])}")
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

    %{sha: seeded_commit("demo")}
  end

  # A real commit in the bare repo via plumbing (no clone, no WAL needed:
  # promotability checks the WAL-backed local repo, and an absent WAL index
  # means nothing to replay).
  defp seeded_commit(repo) do
    path = Repos.ensure_repo!(repo)

    {blob, 0} = git_in(path, ["hash-object", "-w", "--stdin"], "hello\n")
    {tree, 0} = git_in(path, ["mktree"], "100644 blob #{String.trim(blob)}\tfile.txt\n")

    {commit, 0} =
      git_in(path, ["commit-tree", String.trim(tree), "-m", "seed"], "",
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

  defp git_in(path, args, stdin, opts \\ []) do
    input = Path.join(System.tmp_dir!(), "targets-stdin-#{System.unique_integer([:positive])}")
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

  test "promote accepts a pushed SHA, broadcasts, and current/recent see it", %{sha: sha} do
    Phoenix.PubSub.subscribe(OpenAgents.PubSub, "forge:target")

    assert {:ok, target} = Targets.promote("demo", sha, "operator:test")
    assert target.status == "promoted"
    assert_receive {:forge_target, %{repo: "demo", sha: ^sha, target_id: target_id}}
    assert target_id == target.id
    assert Targets.current("demo").id == target.id
    assert [%{id: id}] = Targets.recent("demo")
    assert id == target.id
  end

  test "promote refuses unknown or malformed SHAs" do
    assert {:error, :unknown_sha} =
             Targets.promote("demo", String.duplicate("a", 40), "operator:test")

    assert {:error, :invalid_sha} = Targets.promote("demo", "not-a-sha!", "operator:test")
  end

  test "advance walks the lifecycle, bounds details, and refuses terminal rows", %{sha: sha} do
    {:ok, target} = Targets.promote("demo", sha, "operator:test")

    assert {:ok, %{status: "building"}} = Targets.advance(target.id, "building")

    long = String.duplicate("x", 20_000)
    assert {:ok, built} = Targets.advance(target.id, "built", %{"warnings" => long})
    assert byte_size(built.details["warnings"]) == 8_192

    assert {:ok, _} = Targets.advance(target.id, "deploying")

    assert {:ok, live} =
             Targets.advance(target.id, "live", %{"modules" => ["OpenAgents.BuildInfo"]})

    assert live.status == "live"

    assert {:error, {:invalid_transition, "live", "building"}} =
             Targets.advance(target.id, "building")

    assert {:error, :not_found} = Targets.advance(Ecto.UUID.generate(), "building")
  end

  test "re-promoting an older SHA is just another promotion (pin-back)", %{sha: sha} do
    {:ok, first} = Targets.promote("demo", sha, "operator:test")
    {:ok, _} = Targets.advance(first.id, "building")
    {:ok, second} = Targets.promote("demo", sha, "operator:pin-back")
    assert Targets.current("demo").id == second.id
    assert length(Targets.recent("demo")) == 2
  end
end
