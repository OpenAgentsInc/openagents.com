defmodule OpenAgents.Forge.TargetLifecycleTest do
  use OpenAgents.DataCase, async: false
  alias OpenAgents.Forge.{DeployReceipt, Repos, Targets}

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

  test "deployment ownership refuses a superseded built target", %{sha: sha} do
    {:ok, first} = Targets.promote("demo", sha, "operator:first")
    {:ok, _building} = Targets.advance(first.id, "building")
    {:ok, _built} = Targets.advance(first.id, "built")
    {:ok, second} = Targets.promote("demo", sha, "operator:second")

    assert {:error, :superseded_target} = Targets.begin_deployment(first.id)
    assert Targets.current("demo").id == second.id
    assert Repo.get!(OpenAgents.Forge.Target, first.id).status == "built"
  end

  test "duplicate deployment delivery cannot claim an active target twice", %{sha: sha} do
    {:ok, target} = Targets.promote("demo", sha, "operator:test")
    {:ok, _building} = Targets.advance(target.id, "building")
    {:ok, _built} = Targets.advance(target.id, "built")

    assert {:ok, %{status: "deploying"}} = Targets.begin_deployment(target.id)

    assert {:error, {:invalid_transition, "deploying", "deploying"}} =
             Targets.begin_deployment(target.id)

    assert Repo.get!(OpenAgents.Forge.Target, target.id).status == "deploying"
  end

  test "fleet commit writes the live target and terminal receipt atomically", %{sha: sha} do
    {:ok, target} = Targets.promote("demo", sha, "operator:test")
    {:ok, _building} = Targets.advance(target.id, "building")
    {:ok, _built} = Targets.advance(target.id, "built")
    {:ok, _deploying} = Targets.begin_deployment(target.id)

    deployment_id = Ecto.UUID.generate()
    digest = String.duplicate("a", 64)
    manifest_digest = String.duplicate("b", 64)

    assert {:ok, %{target: live, receipt: receipt}} =
             Targets.finish_deployment(
               target.id,
               "live",
               %{"deployment_id" => deployment_id},
               %{
                 deployment_id: deployment_id,
                 artifact_digest: digest,
                 manifest_digest: manifest_digest,
                 expected_nodes: ["one", "two", "three"],
                 nodes: ["one=committed", "two=committed", "three=committed"],
                 node_results: %{
                   "one" => "committed",
                   "two" => "committed",
                   "three" => "committed"
                 },
                 rollback_verified: nil
               }
             )

    assert live.status == "live"
    assert receipt.result == "live"
    assert receipt.deployment_id == deployment_id
    assert receipt.artifact_digest == digest
    assert receipt.manifest_digest == manifest_digest
  end

  test "PostgreSQL rejects deployment receipt mutation", %{sha: sha} do
    target =
      %OpenAgents.Forge.Target{}
      |> OpenAgents.Forge.Target.changeset(%{
        repo: "demo",
        sha: sha,
        promoted_by: "operator:test",
        status: "failed"
      })
      |> Repo.insert!()

    receipt =
      %DeployReceipt{}
      |> DeployReceipt.changeset(%{
        repo: "demo",
        sha: sha,
        target_id: target.id,
        result: "failed"
      })
      |> Repo.insert!()

    assert_raise Postgrex.Error, ~r/forge deployment receipts are immutable/, fn ->
      Repo.transaction(
        fn ->
          Repo.query!("UPDATE forge_deploys SET result = 'live' WHERE id = $1", [
            Ecto.UUID.dump!(receipt.id)
          ])
        end,
        mode: :savepoint
      )
    end
  end
end
