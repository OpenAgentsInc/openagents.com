defmodule OpenAgents.NetworkStatusTest do
  use OpenAgents.DataCase
  alias OpenAgents.NetworkStatus

  test "the projection is bounded, content-free, and schema-versioned (STATUS-001)" do
    projection = NetworkStatus.projection(refresh: true)

    assert projection["schema"] == "openagents.network_status.v1"
    # Legacy /status compatibility keys survive in the superset.
    assert projection["status"] in ["ok", "degraded"]
    assert is_binary(projection["revision"])

    assert %{"beam" => beam, "raft" => raft, "quorum" => quorum} = projection["cluster"]
    assert is_integer(beam) and beam >= 1
    assert is_integer(raft)
    assert is_boolean(quorum)

    # Nodes carry positional labels only — internal node names/addresses never
    # leave the server.
    rendered = inspect(projection)
    refute rendered =~ to_string(node())

    assert [first | _rest] = projection["nodes"]
    assert first["label"] =~ ~r/^node \d+$/
    assert first["reachable"] == true
    assert is_boolean(first["ready"])
    assert Map.keys(first["boot"]) == ["attempts", "ready", "reason", "retry_in_ms", "state"]
    refute inspect(first["boot"]) =~ ~r/[0-9a-f]{64}/

    assert %{"phase" => _phase, "ready" => _ready, "reason" => _reason} =
             first["deployment"]

    assert is_integer(first["uptime_seconds"])

    # Counts only, never content.
    assert %{"machines_connected" => machines, "active_jobs" => jobs} = projection["counts"]
    assert is_nil(machines) or is_integer(machines)
    assert is_nil(jobs) or is_integer(jobs)
    assert is_list(projection["scvs"])
  end

  # ── STATUS-001: the exact published key set (#173) ────────────────────────
  #
  # STATUS-001 says `/status` and `/api/status` publish counts only, never
  # content, and the tests above pattern-match a few expected values, which
  # tolerates every key beside them. A projection is a struct-shaped thing, so
  # the answer is `LEADERBOARD-001`'s: assert the whole key set, nested sections
  # included, so a key added anywhere in `OpenAgents.NetworkStatus` fails until
  # someone decides it may be published to the internet.
  @published_keys [
    "cluster",
    "cluster.beam",
    "cluster.distributed",
    "cluster.quorum",
    "cluster.raft",
    "counts",
    "counts.active_jobs",
    "counts.machines_connected",
    "forge",
    "forge.loop",
    "forge.loop.last_ms",
    "forge.loop.median_ms",
    "forge.mirror",
    "forge.mirror.lagging_minutes",
    "forge.mirror.repo",
    "forge.mirror.state",
    "forge.recent_deploys",
    "forge.recent_deploys[].at",
    "forge.recent_deploys[].completed_at",
    "forge.recent_deploys[].duration_ms",
    "forge.recent_deploys[].modules",
    "forge.recent_deploys[].push_to_live_ms",
    "forge.recent_deploys[].result",
    "forge.recent_deploys[].sha",
    "forge.recent_deploys[].type",
    "forge.recent_targets",
    "forge.recent_targets[].modules",
    "forge.recent_targets[].promoted_at",
    "forge.recent_targets[].promoted_by",
    "forge.recent_targets[].sha",
    "forge.recent_targets[].status",
    "forge.recent_targets[].updated_at",
    "forge.repo",
    "forge.state",
    "forge.target",
    "forge.target.modules",
    "forge.target.promoted_at",
    "forge.target.promoted_by",
    "forge.target.sha",
    "forge.target.status",
    "forge.target.updated_at",
    "generated_at",
    "independence",
    "independence.degraded",
    # The disclosure's distance from the revision its proofs ran against
    # (#246). A count and a ref name: the two revisions it lies between are
    # commit shas, which this page does not publish.
    "independence.deployment",
    "independence.deployment.behind",
    "independence.deployment.known",
    "independence.deployment.proven_ref",
    "independence.document",
    "independence.export",
    "independence.export.blocked",
    # `independence.export.gaps` is a list, and STATUS-001 declares list-element
    # paths only while the list has an element. It has one: EXIT-001 records
    # the `trace` family blocked, because `POST /api/v1/traces` accepts an
    # upload and nothing reads one back. The three element paths are declared
    # below, which is the decision this contract asks for when a family becomes
    # a gap.
    "independence.export.families",
    "independence.export.gaps",
    "independence.export.gaps[].family",
    "independence.export.gaps[].issue",
    "independence.export.gaps[].status",
    "independence.export.not_user_data",
    "independence.export.partial",
    "independence.export.portable",
    "independence.operator",
    "independence.operator.mirror_is_authority",
    "independence.operator.model",
    "independence.operator.operator_reads_audited",
    "independence.operator.separation_of_duties",
    "independence.private_data",
    "independence.private_data.access_controlled",
    "independence.private_data.encrypted_at_rest",
    "independence.private_data.export_recipient_encryption",
    "independence.private_data.issue",
    "independence.private_data.operator_reads_source",
    "independence.schema",
    "independence.verification",
    # The anchor's address, its publication state, and whether anybody outside
    # the operator witnesses it. Three keys, because ADR 0008 turns on
    # publication and witnessing being different facts.
    "independence.verification.anchor",
    "independence.verification.anchor_published",
    "independence.verification.anchor_witnessed",
    "independence.verification.chained",
    "independence.verification.issue",
    "independence.verification.property",
    "nodes",
    "nodes[].beam_seen",
    "nodes[].boot",
    "nodes[].boot.attempts",
    "nodes[].boot.ready",
    "nodes[].boot.reason",
    "nodes[].boot.retry_in_ms",
    "nodes[].boot.state",
    "nodes[].deployment",
    "nodes[].deployment.phase",
    "nodes[].deployment.ready",
    "nodes[].deployment.reason",
    "nodes[].hot_loaded_at",
    "nodes[].label",
    "nodes[].marker",
    "nodes[].raft_seen",
    "nodes[].reachable",
    "nodes[].ready",
    "nodes[].release",
    "nodes[].revision",
    "nodes[].uptime_seconds",
    "revision",
    "schema",
    "scvs",
    "scvs[].id",
    "scvs[].label",
    "scvs[].status",
    "scvs[].text",
    "scvs[].weight",
    "status"
  ]

  test "the projection publishes exactly the keys STATUS-001 enumerates" do
    seed_every_section!()

    actual = MapSet.new(published_keys(NetworkStatus.projection(refresh: true)))
    declared = MapSet.new(@published_keys)
    undeclared = actual |> MapSet.difference(declared) |> MapSet.to_list()
    stale = declared |> MapSet.difference(actual) |> MapSet.to_list()

    assert undeclared == [],
           """
           `OpenAgents.NetworkStatus` publishes keys STATUS-001 does not name:
           #{inspect(undeclared)}

           `/status` and `/api/status` are anonymous, so a new key is a
           publication decision. Amend STATUS-001 in INVARIANTS.md, then add it
           here.
           """

    assert stale == [],
           """
           STATUS-001 names published keys the projection no longer carries:
           #{inspect(stale)}

           Amend STATUS-001 in INVARIANTS.md, then remove them here.
           """
  end

  test "the degraded projection publishes no key the full one does not" do
    # The page must render during incidents, so every section degrades. What
    # degrading must never do is introduce a key, such as an error string
    # carrying the reason a read failed.
    previous = Application.get_env(:openagents, :forge_repos)
    Application.put_env(:openagents, :forge_repos, ["nothing-here-yet"])
    on_exit(fn -> restore_env(:forge_repos, previous) end)

    actual = MapSet.new(published_keys(NetworkStatus.projection(refresh: true)))
    undeclared = actual |> MapSet.difference(MapSet.new(@published_keys)) |> MapSet.to_list()

    assert undeclared == [],
           """
           A degraded read published keys the healthy projection does not:
           #{inspect(undeclared)}
           """
  end

  # Every published key path, with `[]` standing for a list element. Structs
  # are leaves: a `DateTime` is a value, not a section.
  defp published_keys(value, prefix \\ "")

  defp published_keys(%_struct{}, _prefix), do: []

  defp published_keys(map, prefix) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      path = if prefix == "", do: to_string(key), else: prefix <> "." <> to_string(key)
      [path | published_keys(value, path)]
    end)
  end

  defp published_keys(list, prefix) when is_list(list),
    do: Enum.flat_map(list, &published_keys(&1, prefix <> "[]"))

  defp published_keys(_leaf, _prefix), do: []

  # Every optional section carries data, so an empty list cannot hide the keys
  # its elements would publish.
  defp seed_every_section!() do
    alias OpenAgents.Forge.{DeployReceipt, Target}
    alias OpenAgents.SCV.{DriverAccount, Executions}

    sha = String.duplicate("e", 40)

    target =
      %Target{}
      |> Target.changeset(%{
        repo: "openagents.com",
        sha: sha,
        promoted_by: "operator:1",
        status: "promoted"
      })
      |> Repo.insert!()

    %DeployReceipt{}
    |> DeployReceipt.changeset(%{
      repo: "openagents.com",
      sha: sha,
      target_id: target.id,
      modules: ["Elixir.OpenAgents.Example"],
      result: "live",
      deployment_type: "relup",
      push_to_live_ms: 10,
      started_at: DateTime.add(DateTime.utc_now(), -10, :second),
      completed_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    {:ok, operator} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: "network-status-keys-#{System.unique_integer([:positive])}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    account =
      %DriverAccount{}
      |> DriverAccount.create_changeset(%{
        operator_id: operator.id,
        label: "Published key set",
        secret_ref: "file:published-keys-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()
      |> DriverAccount.ready_changeset(%{
        credential_version: 1,
        plan_type: "pro",
        available_models: ["gpt-5.6-luna"],
        reasoning_efforts: ["low"],
        last_verified_at: DateTime.utc_now()
      })
      |> Repo.update!()

    {:ok, execution} = Executions.claim(account, String.duplicate("d", 40), "objective")

    :ok =
      Executions.record_event(execution, %{
        schema: "openagents.scv.event.v1",
        run_id: execution.id,
        type: "tool_started",
        activity_kind: "searching",
        tool: "grep",
        output: "output"
      })

    # `OpenAgents.Forge.MirrorWatch` publishes its state through a
    # `:persistent_term` key. A watching mirror carries two keys an "off" one
    # does not, and both shapes have to be visible to the key-set assertion.
    mirror_key = {OpenAgents.Forge.MirrorWatch, :state}
    previous = :persistent_term.get(mirror_key, nil)

    :persistent_term.put(mirror_key, %{
      "state" => "lagging",
      "repo" => "openagents.com",
      "lagging_minutes" => 3
    })

    on_exit(fn ->
      if previous,
        do: :persistent_term.put(mirror_key, previous),
        else: :persistent_term.erase(mirror_key)
    end)

    :ok
  end

  test "an unreachable peer degrades to an honest per-node report, not a crash" do
    # A node that is not in the cluster at all — the erpc path must degrade.
    report = NetworkStatus.node_report(:"definitely_not_running@127.0.0.1")
    assert report == %{"reachable" => false}
  end

  test "the projection caches briefly and refresh bypasses the cache" do
    first = NetworkStatus.projection(refresh: true)
    cached = NetworkStatus.projection()
    assert cached["generated_at"] == first["generated_at"]

    refreshed = NetworkStatus.projection(refresh: true)
    assert refreshed["schema"] == first["schema"]
  end

  test "the projection includes durable SCVs running on another node" do
    alias OpenAgents.SCV.{Activity, DriverAccount, Executions}

    {:ok, operator} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: "network-status-scv-#{System.unique_integer([:positive])}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    account =
      %DriverAccount{}
      |> DriverAccount.create_changeset(%{
        operator_id: operator.id,
        label: "Status projection account",
        secret_ref: "file:status-projection-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()
      |> DriverAccount.ready_changeset(%{
        credential_version: 1,
        plan_type: "pro",
        available_models: ["gpt-5.6-luna"],
        reasoning_efforts: ["low"],
        last_verified_at: DateTime.utc_now()
      })
      |> Repo.update!()

    {:ok, execution} =
      Executions.claim(
        account,
        String.duplicate("d", 40),
        "Private objective that must not reach public status."
      )

    event = %{
      schema: "openagents.scv.event.v1",
      run_id: execution.id,
      type: "tool_started",
      activity_kind: "searching",
      tool: "grep",
      output: "private output"
    }

    assert :ok = Executions.record_event(execution, event)
    expected = Activity.project_event(event)
    projection = NetworkStatus.projection(refresh: true)

    assert Enum.find(projection["scvs"], &(&1["id"] == expected["id"])) == expected
    refute inspect(projection["scvs"]) =~ execution.id
    refute inspect(projection["scvs"]) =~ "Private objective"
    refute inspect(projection["scvs"]) =~ "private output"
  end

  test "a single forge node cannot report configured fleet quorum" do
    previous_lane = Application.get_env(:openagents, :forge_deploy_lane_enabled)
    previous_size = Application.get_env(:openagents, :forge_expected_fleet_size)
    Application.put_env(:openagents, :forge_deploy_lane_enabled, true)
    Application.put_env(:openagents, :forge_expected_fleet_size, 3)

    on_exit(fn ->
      restore_env(:forge_deploy_lane_enabled, previous_lane)
      restore_env(:forge_expected_fleet_size, previous_size)
    end)

    projection = NetworkStatus.projection(refresh: true)
    refute projection["cluster"]["quorum"]
    assert projection["status"] == "degraded"
  end

  describe "forge section (#126)" do
    alias OpenAgents.Forge.{DeployReceipt, Target}

    test "degrades to an honest empty shape with no forge data" do
      # Forge rows can leak past the sandbox from other tests' async
      # builders (see AdminForgeLiveTest); an unused repo name makes
      # emptiness deterministic.
      previous = Application.get_env(:openagents, :forge_repos)
      Application.put_env(:openagents, :forge_repos, ["nothing-here-yet"])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:openagents, :forge_repos, previous),
          else: Application.delete_env(:openagents, :forge_repos)
      end)

      forge = NetworkStatus.projection(refresh: true)["forge"]

      assert forge["state"] in ["active", "off"]
      assert forge["target"] == nil
      assert forge["recent_deploys"] == []
      assert forge["loop"] == %{"last_ms" => nil, "median_ms" => nil}
    end

    test "is content-free: short shas, role not identity, module counts not names" do
      sha = String.duplicate("a", 40)

      target =
        %Target{}
        |> Target.changeset(%{
          repo: "openagents.com",
          sha: sha,
          promoted_by: "operator:99887766",
          status: "promoted"
        })
        |> Repo.insert!()

      %DeployReceipt{}
      |> DeployReceipt.changeset(%{
        repo: "openagents.com",
        sha: sha,
        target_id: target.id,
        modules: ["Elixir.OpenAgents.VerySecretModule"],
        result: "live",
        push_to_live_ms: 13_242
      })
      |> Repo.insert!()

      forge = NetworkStatus.projection(refresh: true)["forge"]
      rendered = inspect(forge)

      # Short sha only; the operator role survives, the identity does not;
      # module names never appear — only their count.
      assert forge["target"]["sha"] == String.duplicate("a", 12)
      assert forge["target"]["promoted_by"] == "operator"
      refute rendered =~ "99887766"
      refute rendered =~ "VerySecretModule"

      assert [%{"modules" => 1, "result" => "live", "push_to_live_ms" => 13_242}] =
               forge["recent_deploys"]

      assert forge["loop"]["last_ms"] == 13_242
      assert forge["loop"]["median_ms"] == 13_242
    end

    test "reports whether the preferred deploy loop is active" do
      previous = Application.get_env(:openagents, :forge_deploy_lane_enabled)

      on_exit(fn -> restore_env(:forge_deploy_lane_enabled, previous) end)

      Application.put_env(:openagents, :forge_deploy_lane_enabled, true)
      assert NetworkStatus.projection(refresh: true)["forge"]["state"] == "active"

      Application.put_env(:openagents, :forge_deploy_lane_enabled, false)
      assert NetworkStatus.projection(refresh: true)["forge"]["state"] == "off"
    end

    test "recent deployments expose lane, completion time, and duration, newest first" do
      sha = String.duplicate("c", 40)

      target =
        %Target{}
        |> Target.changeset(%{
          repo: "openagents.com",
          sha: sha,
          promoted_by: "operator:1",
          status: "live"
        })
        |> Repo.insert!()

      now = DateTime.utc_now()

      rows = [
        # Oldest: a pre-column legacy row (no lane recorded).
        %{result: "live", started_at: DateTime.add(now, -100, :millisecond), completed_at: now},
        # A classification-only receipt — no deployment ran.
        %{result: "needs_rolling_replace"},
        %{
          result: "live",
          deployment_type: "direct_load",
          started_at: DateTime.add(now, -1_500, :millisecond),
          completed_at: now
        },
        %{
          result: "failed",
          deployment_type: "relup",
          started_at: DateTime.add(now, -2_000, :millisecond),
          completed_at: now
        },
        # Newest: a rolling replacement.
        %{
          result: "live",
          deployment_type: "rolling_replacement",
          started_at: DateTime.add(now, -60_000, :millisecond),
          completed_at: now
        }
      ]

      for row <- rows do
        %DeployReceipt{}
        |> DeployReceipt.changeset(
          Map.merge(%{repo: "openagents.com", sha: sha, target_id: target.id}, row)
        )
        |> Repo.insert!()

        # Distinct inserted_at ordering under usec timestamps.
        Process.sleep(2)
      end

      deploys = NetworkStatus.projection(refresh: true)["forge"]["recent_deploys"]

      assert [rolling, relup, direct, classification, legacy] = deploys

      assert %{"type" => "rolling_replacement", "result" => "live", "duration_ms" => 60_000} =
               rolling

      assert %{"type" => "relup", "result" => "failed", "duration_ms" => 2_000} = relup
      assert %{"type" => "direct_load", "result" => "live", "duration_ms" => 1_500} = direct

      # Classification-only receipts stay distinguishable: no lane, no
      # duration, and their own result.
      assert %{"type" => nil, "result" => "needs_rolling_replace", "duration_ms" => nil} =
               classification

      # Rows older than the lane column degrade honestly to a nil type while
      # keeping their measured duration.
      assert %{"type" => nil, "result" => "live", "duration_ms" => 100} = legacy

      for deploy <- deploys do
        assert {:ok, _at, _offset} = DateTime.from_iso8601(deploy["completed_at"])
      end
    end

    test "loop metrics: last is newest, median over live deploys only" do
      sha = String.duplicate("b", 40)

      target =
        %Target{}
        |> Target.changeset(%{
          repo: "openagents.com",
          sha: sha,
          promoted_by: "operator:1",
          status: "live"
        })
        |> Repo.insert!()

      for {result, ms} <- [{"live", 30_000}, {"failed", nil}, {"live", 20_000}, {"live", 10_000}] do
        %DeployReceipt{}
        |> DeployReceipt.changeset(%{
          repo: "openagents.com",
          sha: sha,
          target_id: target.id,
          result: result,
          push_to_live_ms: ms
        })
        |> Repo.insert!()

        # Distinct inserted_at ordering under usec timestamps.
        Process.sleep(2)
      end

      loop = NetworkStatus.projection(refresh: true)["forge"]["loop"]
      assert loop["last_ms"] == 10_000
      assert loop["median_ms"] == 20_000
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
