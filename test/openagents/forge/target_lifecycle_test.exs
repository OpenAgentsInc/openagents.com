defmodule OpenAgents.Forge.TargetLifecycleTest do
  use OpenAgents.DataCase, async: false
  import OpenAgents.AccountsFixtures

  alias OpenAgents.Forge.{BuildReceipt, DeployReceipt, Repos, Targets}

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

  test "promotion resolves a repository name to its UUID storage key" do
    user = repository_user_fixture("target-storage-owner")

    {:ok, repository, :created} =
      OpenAgents.Repositories.create_user_repository(
        user,
        %{name: "mapped-target"},
        "target-storage-key"
      )

    repository =
      repository
      |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
      |> OpenAgents.Repo.update!()

    sha = seeded_commit(repository.storage_key)
    previous_repos = Application.get_env(:openagents, :forge_repos)
    Application.put_env(:openagents, :forge_repos, [repository.name])

    on_exit(fn -> Application.put_env(:openagents, :forge_repos, previous_repos) end)

    assert {:ok, target} = Targets.promote(repository.name, sha, "operator:test")
    assert target.sha == sha
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

  test "rolling replacement settlement makes the verified build the live baseline", %{sha: sha} do
    {:ok, target} = Targets.promote("demo", sha, "operator:test")
    {:ok, _building} = Targets.advance(target.id, "building")
    {:ok, _built} = Targets.advance(target.id, "built")
    {:ok, _rolling} = Targets.advance(target.id, "needs_rolling_replace")

    artifact_digest = String.duplicate("a", 64)
    manifest = %{"classification" => "needs_rolling_replace", "source_sha" => sha}

    insert_build_receipt!(target, manifest, artifact_digest)

    assert {:ok, %{target: live, receipt: receipt}} =
             Targets.finish_rolling_replacement(target.id, rolling_result(sha, "live"))

    assert live.status == "live"
    assert live.details["image_digest"] == "sha256:" <> String.duplicate("c", 64)
    assert receipt.result == "live"
    assert receipt.artifact_digest == artifact_digest
    assert receipt.modules == ["Elixir.OpenAgents.BuildInfo"]
    assert receipt.expected_nodes == ["openagents@10.42.0.11", "openagents@10.42.0.12"]

    assert receipt.node_results == %{
             "openagents@10.42.0.11" => "ready",
             "openagents@10.42.0.12" => "ready"
           }

    assert Targets.live("demo").id == target.id

    assert {:error, {:invalid_transition, "live", "live"}} =
             Targets.finish_rolling_replacement(target.id, rolling_result(sha, "live"))
  end

  test "rolling replacement settlement refuses a superseded target", %{sha: sha} do
    {:ok, first} = Targets.promote("demo", sha, "operator:first")
    {:ok, _building} = Targets.advance(first.id, "building")
    {:ok, _built} = Targets.advance(first.id, "built")
    {:ok, _rolling} = Targets.advance(first.id, "needs_rolling_replace")
    insert_build_receipt!(first, %{"source_sha" => sha}, String.duplicate("a", 64))

    {:ok, second} = Targets.promote("demo", sha, "operator:second")

    assert {:error, :superseded_target} =
             Targets.finish_rolling_replacement(first.id, rolling_result(sha, "live"))

    assert Targets.current("demo").id == second.id
  end

  test "rolling replacement settlement records a verified rollback failure", %{sha: sha} do
    {:ok, target} = Targets.promote("demo", sha, "operator:test")
    {:ok, _building} = Targets.advance(target.id, "building")
    {:ok, _built} = Targets.advance(target.id, "built")
    {:ok, _rolling} = Targets.advance(target.id, "needs_rolling_replace")
    insert_build_receipt!(target, %{"source_sha" => sha}, String.duplicate("a", 64))

    result =
      rolling_result(sha, "failed")
      |> Map.put(:node_results, %{
        "openagents@10.42.0.11" => "ready",
        "openagents@10.42.0.12" => "rejoin_check_failed"
      })
      |> Map.put(:error_code, "rejoin_check_failed")
      |> Map.put(:recovery, "last_known_good_restored")

    assert {:ok, %{target: failed, receipt: receipt}} =
             Targets.finish_rolling_replacement(target.id, result)

    assert failed.status == "failed"
    assert receipt.result == "failed"
    assert receipt.rollback_verified
    assert receipt.error_code == "rejoin_check_failed"
  end

  test "rolling replacement settlement requires a complete build receipt", %{sha: sha} do
    {:ok, target} = Targets.promote("demo", sha, "operator:test")
    {:ok, _building} = Targets.advance(target.id, "building")
    {:ok, _built} = Targets.advance(target.id, "built")
    {:ok, _rolling} = Targets.advance(target.id, "needs_rolling_replace")

    assert {:error, :complete_build_receipt_not_found} =
             Targets.finish_rolling_replacement(target.id, rolling_result(sha, "live"))
  end

  test "rolling replacement settlement refuses a result for another SHA", %{sha: sha} do
    {:ok, target} = Targets.promote("demo", sha, "operator:test")
    {:ok, _building} = Targets.advance(target.id, "building")
    {:ok, _built} = Targets.advance(target.id, "built")
    {:ok, _rolling} = Targets.advance(target.id, "needs_rolling_replace")
    insert_build_receipt!(target, %{"source_sha" => sha}, String.duplicate("a", 64))

    assert {:error, :rolling_sha_mismatch} =
             Targets.finish_rolling_replacement(
               target.id,
               rolling_result(String.duplicate("e", 40), "live")
             )

    assert Repo.get!(OpenAgents.Forge.Target, target.id).status == "needs_rolling_replace"
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

  defp insert_build_receipt!(target, manifest, artifact_digest) do
    %BuildReceipt{}
    |> BuildReceipt.changeset(%{
      repo: target.repo,
      sha: target.sha,
      target_id: target.id,
      status: "complete",
      manifest: manifest,
      modules: ["Elixir.OpenAgents.BuildInfo"],
      artifact: "#{artifact_digest}.tar.gz",
      artifact_digest: artifact_digest,
      duration_ms: 1,
      completed_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp rolling_result(sha, status) do
    %{
      schema: "openagents.rolling-replacement.v1",
      sha: sha,
      previous_sha: String.duplicate("b", 40),
      image_digest: "sha256:" <> String.duplicate("c", 64),
      previous_image_digest: "sha256:" <> String.duplicate("d", 64),
      status: status,
      node_results: %{
        "openagents@10.42.0.11" => "ready",
        "openagents@10.42.0.12" => "ready"
      },
      error_code: nil,
      recovery: nil
    }
  end
end
