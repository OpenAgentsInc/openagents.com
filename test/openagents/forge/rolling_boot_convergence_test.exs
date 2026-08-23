defmodule OpenAgents.Forge.RollingBootConvergenceTest do
  @moduledoc """
  A three-node rolling replacement with boot convergence enabled throughout
  (#25).

  The 2026-08-22 production rollout could only finish because an operator
  disabled `OPENAGENTS_FEATURE_BOOT_CONVERGENCE` while the three nodes rolled
  and restarted `OpenAgents.Forge.BootConverge` by hand afterwards. These
  tests hold the feature on for their whole duration and never touch that
  worker, so anything that still needed the workaround fails here.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.BootConverge
  alias OpenAgents.Forge.BuildReceipt
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Forge.RollingReplacement
  alias OpenAgents.Forge.Target
  alias OpenAgents.Forge.Targets
  alias OpenAgents.Repo
  alias OpenAgents.Test.RollingFleet

  @repo "demo"
  @nodes [:"openagents@10.0.0.1", :"openagents@10.0.0.2", :"openagents@10.0.0.3"]
  @node_names ["openagents@10.0.0.1", "openagents@10.0.0.2", "openagents@10.0.0.3"]
  @digest "sha256:" <> String.duplicate("1", 64)
  @previous_digest "sha256:" <> String.duplicate("2", 64)
  @previous_sha String.duplicate("b", 40)

  setup do
    base = Path.join(System.tmp_dir!(), "rolling-boot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    previous =
      for key <- [:forge_data_dir, :forge_wal_dir, :image_digest, :forge_boot_converge_enabled] do
        {key, Application.get_env(:openagents, key)}
      end

    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    # Enabled once, here, and never changed again by any test in this file.
    Application.put_env(:openagents, :forge_boot_converge_enabled, true)

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:openagents, key),
          else: Application.put_env(:openagents, key, value)
      end

      File.rm_rf(base)
      :persistent_term.erase({BootConverge, :state})
    end)

    sha = seeded_commit(@repo)
    live_target!()
    target = rolling_target!(sha)
    insert_build_receipt!(target, sha)

    start_supervised!(
      {RollingFleet,
       %{
         repo: @repo,
         nodes: @nodes,
         fail_node: nil,
         identities: Map.new(@nodes, &{&1, previous_identity()})
       }}
    )

    %{sha: sha, target: target}
  end

  test "three nodes roll to the authorized image with the feature flag untouched", %{
    sha: sha,
    target: target
  } do
    assert Application.get_env(:openagents, :forge_boot_converge_enabled) == true

    # Before the roll, no rolling identity is authorized and every node serves
    # only because it runs the live image.
    assert Targets.rolling_authority(@repo) == nil
    assert BootConverge.classify(@repo, previous_identity()) == :live
    assert BootConverge.classify(@repo, new_identity(sha)) == :divergent

    assert {:ok, result} = roll(sha, target)
    assert result.status == "live"
    assert result.target_id == target.id

    assert result.node_results == %{
             "openagents@10.0.0.1" => "ready",
             "openagents@10.0.0.2" => "ready",
             "openagents@10.0.0.3" => "ready"
           }

    # One node at a time, in the exact expected order.
    assert Enum.filter(RollingFleet.events(), &match?({:replace, _node, _digest}, &1)) ==
             Enum.map(@nodes, &{:replace, &1, @digest})

    # Load balancer health: boot convergence admitted every node at every
    # sample, and two nodes were always in rotation. The 2026-08-22 rollout
    # could not say this — a replaced node reported 503 for the whole roll.
    assert RollingFleet.health() != []
    assert Enum.all?(RollingFleet.health(), &(&1.admitted == 3))
    assert Enum.min(Enum.map(RollingFleet.health(), & &1.serving)) == 2

    # Quorum: the coordinator only ever saw a quorate remaining fleet.
    assert Enum.all?(RollingFleet.health(), &(&1.serving * 2 > 3))

    # Exact SHA and image digest on every node.
    assert RollingFleet.identities() == Map.new(@nodes, &{&1, new_identity(sha)})

    # Every node recorded its exact identity against the published authority.
    authority = Targets.rolling_authority(@repo)
    assert authority["expected_nodes"] == @node_names
    assert authority["image_digest"] == @digest
    assert authority["sha"] == sha
    assert Enum.sort(Map.keys(authority["observed"])) == @node_names

    assert Enum.all?(@node_names, fn node ->
             observed = authority["observed"][node]
             observed["sha"] == sha and observed["image_digest"] == @digest
           end)

    # Settlement.
    assert {:ok, %{target: live, receipt: receipt}} =
             Targets.finish_rolling_replacement(target.id, result)

    assert live.status == "live"
    assert live.details["image_digest"] == @digest
    assert receipt.result == "live"
    assert receipt.expected_nodes == @node_names
    assert Targets.rolling_authority(@repo) == nil

    # After settlement every node is admitted through the live identity, and
    # the old image no longer is.
    assert BootConverge.classify(@repo, new_identity(sha)) == :live
    assert BootConverge.classify(@repo, previous_identity()) == :divergent
  end

  test "a node booting mid-roll converges and settles without a restart", %{target: target} do
    # This node's own booted revision, so its own convergence worker is a
    # participant in the roll rather than an observer of one.
    rolling =
      target
      |> Ecto.Changeset.change(%{sha: OpenAgents.BuildInfo.revision()})
      |> Repo.update!()

    Application.put_env(:openagents, :image_digest, @digest)
    authorize!(rolling, rolling.sha)

    pid =
      start_supervised!(
        {BootConverge, name: :rolling_boot_convergence_worker, repo: @repo},
        id: :rolling_boot_convergence_worker
      )

    # A node that boots into the authorized image is ready on its first
    # attempt. No flag change, no manual convergence run.
    assert %{"reason" => "image_matches_rolling_target", "ready" => true} = BootConverge.state()
    assert BootConverge.ready?(@repo)

    # Rebooting that node mid-roll converges the same way.
    stop_supervised!(:rolling_boot_convergence_worker)

    restarted =
      start_supervised!(
        {BootConverge, name: :rolling_boot_convergence_worker, repo: @repo},
        id: :rolling_boot_convergence_worker
      )

    assert restarted != pid
    assert %{"reason" => "image_matches_rolling_target", "ready" => true} = BootConverge.state()

    # Settlement flips the target live; the worker's own periodic attempt
    # follows the live identity without anyone restarting it.
    rolling
    |> Ecto.Changeset.change(%{
      status: "live",
      details: Map.put(rolling.details, "image_digest", @digest)
    })
    |> Repo.update!()

    send(restarted, :retry_convergence)
    _synchronized = :sys.get_state(restarted)

    assert Process.alive?(restarted)
    assert %{"reason" => "image_matches_live", "ready" => true} = BootConverge.state()
    assert BootConverge.ready?(@repo)
  end

  test "a failure before settlement is recoverable and auditable", %{sha: sha, target: target} do
    stop_supervised!(RollingFleet)

    start_supervised!(
      {RollingFleet,
       %{
         repo: @repo,
         nodes: @nodes,
         fail_node: :"openagents@10.0.0.2",
         identities: Map.new(@nodes, &{&1, previous_identity()})
       }}
    )

    assert {:error, failed} = roll(sha, target)
    assert failed.status == "failed"
    assert failed.recovery == "last_known_good_restored"

    # The third node was never touched.
    refute {:replace, :"openagents@10.0.0.3", @digest} in RollingFleet.events()

    # Auditable: the authority says exactly which node came back on which
    # identity, and the rolled-back node reads as the previous image.
    authority = Targets.rolling_authority(@repo)
    assert authority["observed"]["openagents@10.0.0.1"]["image_digest"] == @digest

    assert authority["observed"]["openagents@10.0.0.2"]["image_digest"] ==
             @previous_digest

    refute Map.has_key?(authority["observed"], "openagents@10.0.0.3")

    # Not settleable as live: an interrupted roll cannot claim the fleet runs
    # the new image.
    assert {:error, :rolling_nodes_not_converged} =
             Targets.finish_rolling_replacement(target.id, live_result(sha, target))

    assert Repo.get!(Target, target.id).status == "needs_rolling_replace"

    # Recoverable: rerunning the same roll resumes against the same published
    # authority and finishes.
    RollingFleet.clear_failure()
    assert {:ok, result} = roll(sha, target)
    assert result.status == "live"

    assert {:ok, %{target: live}} = Targets.finish_rolling_replacement(target.id, result)
    assert live.status == "live"
    assert live.details["rolling_authority"]["authorized_by"] == "operator:test"
  end

  test "a node that diverges after settlement leaves service", %{sha: sha, target: target} do
    assert {:ok, result} = roll(sha, target)
    assert {:ok, %{target: live}} = Targets.finish_rolling_replacement(target.id, result)
    assert live.status == "live"

    # No rolling authority survives settlement, so a stale or unexpected image
    # has nothing left to claim admission from.
    assert Targets.rolling_authority(@repo) == nil

    foreign = %{sha: sha, image_digest: "sha256:" <> String.duplicate("e", 64)}
    RollingFleet.put_identity(:"openagents@10.0.0.3", foreign)

    assert BootConverge.classify(@repo, foreign) == :divergent

    assert {:ok, %{ready: 2, quorum: true}} =
             RollingFleet.capacity(@nodes, %{
               sha: sha,
               previous_sha: @previous_sha,
               image_digest: @digest,
               previous_image_digest: @previous_digest,
               expected_nodes: @nodes
             })

    # The settled target is immutable authority; it cannot be re-settled.
    assert {:error, {:invalid_transition, "live", "live"}} =
             Targets.finish_rolling_replacement(target.id, result)
  end

  defp roll(sha, target) do
    RollingReplacement.run(
      %{
        target_id: target.id,
        sha: sha,
        previous_sha: @previous_sha,
        image_digest: @digest,
        previous_image_digest: @previous_digest,
        expected_nodes: @nodes,
        expected_fleet_size: 3,
        minimum_ready: 2,
        authorized_by: "operator:test"
      },
      provider: RollingFleet,
      gate_verifier: fn ^sha -> {:ok, %{}} end,
      wait_attempts: 3,
      wait_interval_ms: 0
    )
  end

  defp live_result(sha, target) do
    %{
      schema: "openagents.rolling-replacement.v1",
      target_id: target.id,
      sha: sha,
      previous_sha: @previous_sha,
      image_digest: @digest,
      previous_image_digest: @previous_digest,
      status: "live",
      node_results: Map.new(@node_names, &{&1, "ready"}),
      error_code: nil,
      recovery: nil
    }
  end

  defp previous_identity, do: %{sha: @previous_sha, image_digest: @previous_digest}
  defp new_identity(sha), do: %{sha: sha, image_digest: @digest}

  defp authorize!(target, sha) do
    {:ok, authorized} =
      Targets.authorize_rolling_replacement(target.id, %{
        sha: sha,
        image_digest: @digest,
        previous_sha: @previous_sha,
        previous_image_digest: @previous_digest,
        expected_nodes: @node_names,
        authorized_by: "operator:test"
      })

    authorized
  end

  defp live_target! do
    %Target{}
    |> Target.changeset(%{
      repo: @repo,
      sha: @previous_sha,
      promoted_by: "operator:test",
      status: "promoted",
      details: %{"image_digest" => @previous_digest}
    })
    |> Repo.insert!()
    |> Ecto.Changeset.change(%{status: "live"})
    |> Repo.update!()
  end

  defp rolling_target!(sha) do
    {:ok, target} = Targets.promote(@repo, sha, "operator:test")
    {:ok, _building} = Targets.advance(target.id, "building")
    {:ok, _built} = Targets.advance(target.id, "built")
    {:ok, rolling} = Targets.advance(target.id, "needs_rolling_replace")
    rolling
  end

  defp insert_build_receipt!(target, sha) do
    %BuildReceipt{}
    |> BuildReceipt.changeset(%{
      repo: target.repo,
      sha: target.sha,
      target_id: target.id,
      status: "complete",
      manifest: %{"classification" => "needs_rolling_replace", "source_sha" => sha},
      modules: ["Elixir.OpenAgents.BuildInfo"],
      artifact: String.duplicate("a", 64) <> ".tar.gz",
      artifact_digest: String.duplicate("a", 64),
      duration_ms: 1,
      completed_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp seeded_commit(repo) do
    path = Repos.ensure_repo!(repo)

    {blob, 0} = git_in(path, ["hash-object", "-w", "--stdin"], "rolling\n")
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
    {_output, 0} = Repos.git(path, ["update-ref", "refs/heads/main", sha])
    sha
  end

  defp git_in(path, args, stdin, opts \\ []) do
    input = Path.join(System.tmp_dir!(), "rolling-stdin-#{System.unique_integer([:positive])}")
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
end
