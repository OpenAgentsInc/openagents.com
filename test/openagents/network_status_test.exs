defmodule OpenAgents.NetworkStatusTest do
  use OpenAgents.SarahDataCase
  @moduletag :skip
  alias OpenAgents.NetworkStatus

  test "the projection is bounded, content-free, and schema-versioned (STATUS-001)" do
    projection = NetworkStatus.projection(refresh: true)

    assert projection["schema"] == "sarah.network_status.v1"
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
    assert is_integer(first["uptime_seconds"])

    # Counts only, never content.
    assert %{"machines_connected" => machines, "active_jobs" => jobs} = projection["counts"]
    assert is_nil(machines) or is_integer(machines)
    assert is_nil(jobs) or is_integer(jobs)
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

      assert forge["target"] == nil
      assert forge["recent_deploys"] == []
      assert forge["loop"] == %{"last_ms" => nil, "median_ms" => nil}
    end

    test "is content-free: short shas, role not identity, module counts not names" do
      sha = String.duplicate("a", 40)

      target =
        %Target{}
        |> Target.changeset(%{
          repo: "sarah",
          sha: sha,
          promoted_by: "operator:99887766",
          status: "promoted"
        })
        |> Repo.insert!()

      %DeployReceipt{}
      |> DeployReceipt.changeset(%{
        repo: "sarah",
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

    test "loop metrics: last is newest, median over live deploys only" do
      sha = String.duplicate("b", 40)

      target =
        %Target{}
        |> Target.changeset(%{repo: "sarah", sha: sha, promoted_by: "operator:1", status: "live"})
        |> Repo.insert!()

      for {result, ms} <- [{"live", 30_000}, {"failed", nil}, {"live", 20_000}, {"live", 10_000}] do
        %DeployReceipt{}
        |> DeployReceipt.changeset(%{
          repo: "sarah",
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
end
