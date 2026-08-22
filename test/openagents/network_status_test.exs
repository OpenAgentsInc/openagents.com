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
