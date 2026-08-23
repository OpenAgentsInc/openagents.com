defmodule OpenAgents.Forge.TargetLifecycleTest do
  use OpenAgents.DataCase, async: false
  import OpenAgents.AccountsFixtures

  alias OpenAgents.Forge.{BuildReceipt, DeployReceipt, Repos, Targets}

  @rolling_nodes ["openagents@10.42.0.11", "openagents@10.42.0.12"]
  @rolling_digest "sha256:" <> String.duplicate("c", 64)
  @rolling_previous_digest "sha256:" <> String.duplicate("d", 64)
  @rolling_previous_sha String.duplicate("b", 40)

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
    authorize_rolling!(target, sha)
    observe_rolling!(target, sha)

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

  test "relup settlement makes the verified package the live baseline", %{sha: sha} do
    {:ok, target} = Targets.promote("demo", sha, "operator:test")
    {:ok, _building} = Targets.advance(target.id, "building")
    {:ok, _built} = Targets.advance(target.id, "built")
    {:ok, _relup} = Targets.advance(target.id, "needs_rolling_replace")

    build_digest = String.duplicate("a", 64)
    package_digest = String.duplicate("c", 64)
    package_manifest_digest = String.duplicate("d", 64)

    insert_build_receipt!(
      target,
      %{"classification" => "needs_rolling_replace", "source_sha" => sha},
      build_digest
    )

    result =
      relup_result(sha, "live")
      |> Map.put(:artifact_digest, package_digest)
      |> Map.put(:package_manifest_digest, package_manifest_digest)

    assert {:ok, %{target: live, receipt: receipt}} =
             Targets.finish_relup_deployment(target.id, result)

    assert live.status == "live"
    assert live.details["deployment_lane"] == "relup"
    assert live.details["artifact_digest"] == package_digest
    assert live.details["build_artifact_digest"] == build_digest
    assert receipt.result == "live"
    assert receipt.artifact_digest == package_digest
    assert receipt.manifest_digest == package_manifest_digest
    assert receipt.push_to_live_ms == 53_876

    assert receipt.node_results == %{
             "openagents@10.42.0.11" => "permanent",
             "openagents@10.42.0.12" => "permanent"
           }
  end

  test "relup settlement refuses a nonpermanent live result", %{sha: sha} do
    {:ok, target} = Targets.promote("demo", sha, "operator:test")
    {:ok, _building} = Targets.advance(target.id, "building")
    {:ok, _built} = Targets.advance(target.id, "built")
    {:ok, _relup} = Targets.advance(target.id, "needs_rolling_replace")
    insert_build_receipt!(target, %{"source_sha" => sha}, String.duplicate("a", 64))

    result =
      relup_result(sha, "live")
      |> put_in([:node_results, "openagents@10.42.0.12"], "current")

    assert {:error, :invalid_relup_result} =
             Targets.finish_relup_deployment(target.id, result)

    assert Repo.get!(OpenAgents.Forge.Target, target.id).status == "needs_rolling_replace"
  end

  test "rolling replacement records a complete large module inventory", %{sha: sha} do
    {:ok, target} = Targets.promote("demo", sha, "operator:test")
    {:ok, _building} = Targets.advance(target.id, "building")
    {:ok, _built} = Targets.advance(target.id, "built")
    {:ok, _rolling} = Targets.advance(target.id, "needs_rolling_replace")

    modules = Enum.map(1..600, &"Elixir.OpenAgents.Generated.Module#{&1}")

    insert_build_receipt!(
      target,
      %{"classification" => "needs_rolling_replace", "source_sha" => sha},
      String.duplicate("a", 64),
      modules
    )

    authorize_rolling!(target, sha)
    observe_rolling!(target, sha)

    assert {:ok, %{receipt: receipt}} =
             Targets.finish_rolling_replacement(target.id, rolling_result(sha, "live"))

    assert receipt.modules == modules
  end

  test "rolling replacement settlement refuses a superseded target", %{sha: sha} do
    {:ok, first} = Targets.promote("demo", sha, "operator:first")
    {:ok, _building} = Targets.advance(first.id, "building")
    {:ok, _built} = Targets.advance(first.id, "built")
    {:ok, _rolling} = Targets.advance(first.id, "needs_rolling_replace")
    insert_build_receipt!(first, %{"source_sha" => sha}, String.duplicate("a", 64))
    authorize_rolling!(first, sha)
    observe_rolling!(first, sha)

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
    authorize_rolling!(target, sha)

    assert {:ok, _observed} =
             Targets.record_rolling_node(target.id, "openagents@10.42.0.11", %{
               sha: sha,
               image_digest: @rolling_digest
             })

    assert {:ok, _rolled_back} =
             Targets.record_rolling_node(target.id, "openagents@10.42.0.12", %{
               sha: @rolling_previous_sha,
               image_digest: @rolling_previous_digest
             })

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
    authorize_rolling!(target, sha)
    observe_rolling!(target, sha)

    assert {:error, :complete_build_receipt_not_found} =
             Targets.finish_rolling_replacement(target.id, rolling_result(sha, "live"))
  end

  test "rolling settlement refuses until every node reports the authorized identity",
       %{sha: sha} do
    target = rolling_target!(sha)
    insert_build_receipt!(target, %{"source_sha" => sha}, String.duplicate("a", 64))
    authorize_rolling!(target, sha)
    observe_rolling!(target, sha, ["openagents@10.42.0.11"])

    assert {:error, :rolling_nodes_not_converged} =
             Targets.finish_rolling_replacement(target.id, rolling_result(sha, "live"))

    assert Repo.get!(OpenAgents.Forge.Target, target.id).status == "needs_rolling_replace"

    # A node that came back on some other image is not a converged node.
    assert {:ok, _divergent} =
             Targets.record_rolling_node(target.id, "openagents@10.42.0.12", %{
               sha: sha,
               image_digest: "sha256:" <> String.duplicate("e", 64)
             })

    assert {:error, :rolling_nodes_not_converged} =
             Targets.finish_rolling_replacement(target.id, rolling_result(sha, "live"))

    observe_rolling!(target, sha, ["openagents@10.42.0.12"])

    assert {:ok, %{target: live}} =
             Targets.finish_rolling_replacement(target.id, rolling_result(sha, "live"))

    assert live.status == "live"
    assert live.details["rolling_authority"]["authorized_by"] == "operator:test"
  end

  test "rolling settlement refuses a target that published no authority", %{sha: sha} do
    target = rolling_target!(sha)
    insert_build_receipt!(target, %{"source_sha" => sha}, String.duplicate("a", 64))

    assert {:error, :rolling_authority_missing} =
             Targets.finish_rolling_replacement(target.id, rolling_result(sha, "live"))

    assert Repo.get!(OpenAgents.Forge.Target, target.id).status == "needs_rolling_replace"
  end

  test "rolling settlement refuses a result for another image identity", %{sha: sha} do
    target = rolling_target!(sha)
    insert_build_receipt!(target, %{"source_sha" => sha}, String.duplicate("a", 64))
    authorize_rolling!(target, sha)
    observe_rolling!(target, sha)

    result =
      rolling_result(sha, "live")
      |> Map.put(:image_digest, "sha256:" <> String.duplicate("e", 64))

    assert {:error, :rolling_authority_mismatch} =
             Targets.finish_rolling_replacement(target.id, result)
  end

  test "rolling settlement refuses a result for another node set", %{sha: sha} do
    target = rolling_target!(sha)
    insert_build_receipt!(target, %{"source_sha" => sha}, String.duplicate("a", 64))
    authorize_rolling!(target, sha)
    observe_rolling!(target, sha)

    result =
      rolling_result(sha, "live")
      |> Map.put(:node_results, %{"openagents@10.42.0.11" => "ready"})

    assert {:error, :rolling_node_set_mismatch} =
             Targets.finish_rolling_replacement(target.id, result)
  end

  test "republishing the same rolling identity resumes without losing observations",
       %{sha: sha} do
    target = rolling_target!(sha)
    authorize_rolling!(target, sha)
    observe_rolling!(target, sha, ["openagents@10.42.0.11"])

    resumed = authorize_rolling!(target, sha)

    assert Map.keys(resumed.details["rolling_authority"]["observed"]) == [
             "openagents@10.42.0.11"
           ]
  end

  test "republishing a different rolling identity is refused once a node is observed",
       %{sha: sha} do
    target = rolling_target!(sha)
    authorize_rolling!(target, sha)

    redirected =
      rolling_identity(sha)
      |> Map.put(:image_digest, "sha256:" <> String.duplicate("e", 64))

    # Before any node runs the authorized image the operator may still redirect.
    assert {:ok, _redirected} =
             Targets.authorize_rolling_replacement(target.id, redirected)

    assert {:ok, _observed} =
             Targets.record_rolling_node(target.id, "openagents@10.42.0.11", %{
               sha: sha,
               image_digest: "sha256:" <> String.duplicate("e", 64)
             })

    assert {:error, :rolling_authority_conflict} =
             Targets.authorize_rolling_replacement(target.id, rolling_identity(sha))
  end

  test "rolling authorization requires a classified target and its exact SHA", %{sha: sha} do
    {:ok, target} = Targets.promote("demo", sha, "operator:test")

    assert {:error, {:invalid_transition, "promoted", "needs_rolling_replace"}} =
             Targets.authorize_rolling_replacement(target.id, rolling_identity(sha))

    classified = rolling_target!(sha)

    assert {:error, :rolling_authority_sha_mismatch} =
             Targets.authorize_rolling_replacement(
               classified.id,
               rolling_identity(String.duplicate("e", 40))
             )

    assert {:error, :invalid_rolling_authority} =
             Targets.authorize_rolling_replacement(
               classified.id,
               Map.put(rolling_identity(sha), :image_digest, "not-a-digest")
             )
  end

  test "an unexpected node cannot record itself against a rolling authority", %{sha: sha} do
    target = rolling_target!(sha)
    authorize_rolling!(target, sha)

    assert {:error, :rolling_node_not_expected} =
             Targets.record_rolling_node(target.id, "openagents@10.42.0.99", %{
               sha: sha,
               image_digest: @rolling_digest
             })

    assert {:error, :invalid_rolling_observation} =
             Targets.record_rolling_node(target.id, "openagents@10.42.0.11", %{
               sha: sha,
               image_digest: "not-a-digest"
             })
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

  defp insert_build_receipt!(
         target,
         manifest,
         artifact_digest,
         modules \\ ["Elixir.OpenAgents.BuildInfo"]
       ) do
    %BuildReceipt{}
    |> BuildReceipt.changeset(%{
      repo: target.repo,
      sha: target.sha,
      target_id: target.id,
      status: "complete",
      manifest: manifest,
      modules: modules,
      artifact: "#{artifact_digest}.tar.gz",
      artifact_digest: artifact_digest,
      duration_ms: 1,
      completed_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp rolling_target!(sha) do
    {:ok, target} = Targets.promote("demo", sha, "operator:test")
    {:ok, _building} = Targets.advance(target.id, "building")
    {:ok, _built} = Targets.advance(target.id, "built")
    {:ok, rolling} = Targets.advance(target.id, "needs_rolling_replace")
    rolling
  end

  defp authorize_rolling!(target, sha) do
    assert {:ok, authorized} =
             Targets.authorize_rolling_replacement(target.id, rolling_identity(sha))

    authorized
  end

  defp rolling_identity(sha) do
    %{
      sha: sha,
      image_digest: @rolling_digest,
      previous_sha: @rolling_previous_sha,
      previous_image_digest: @rolling_previous_digest,
      expected_nodes: @rolling_nodes,
      authorized_by: "operator:test"
    }
  end

  defp observe_rolling!(target, sha, nodes \\ @rolling_nodes) do
    for node <- nodes do
      assert {:ok, _observed} =
               Targets.record_rolling_node(target.id, node, %{
                 sha: sha,
                 image_digest: @rolling_digest
               })
    end
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

  defp relup_result(sha, status) do
    %{
      schema: "openagents.relup-deployment.v1",
      sha: sha,
      from_revision: String.duplicate("b", 40),
      artifact_digest: String.duplicate("c", 64),
      package_manifest_digest: String.duplicate("d", 64),
      from_version: "0.2.0",
      to_version: "0.2.1",
      status: status,
      node_results: %{
        "openagents@10.42.0.11" => "permanent",
        "openagents@10.42.0.12" => "permanent"
      },
      error_code: nil,
      duration_ms: 53_876
    }
  end
end
