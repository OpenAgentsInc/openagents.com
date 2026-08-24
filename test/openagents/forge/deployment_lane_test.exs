defmodule OpenAgents.Forge.DeploymentLaneTest do
  @moduledoc """
  A candidate's lane is chosen from the fleet's own topology verdict, before
  any node is touched (RELEASE-009).

  These tests hold three things: the direct and rolling split the hot loader
  already made stays exactly what it was, a fleet that cannot support relup
  never enters the relup lane, and the verdict is recorded on every
  classification whether or not it decided anything.
  """
  use ExUnit.Case, async: true

  alias OpenAgents.Forge.DeploymentLane

  @relup_reasons [
    "toolchain_application_spec_sha256_changed",
    "toolchain_application_version_changed"
  ]

  defp manifest(reasons) do
    %{
      "classification" =>
        if(reasons == [], do: "direct_candidate", else: "needs_rolling_replace"),
      "structural_reasons" => reasons
    }
  end

  defp supported_topology do
    DeploymentLane.fleet_topology(
      members: fn -> [:a@fleet, :b@fleet] end,
      report: fn _node, _opts -> {:ok, %{"incompatible" => []}} end
    )
  end

  defp libring_topology do
    DeploymentLane.fleet_topology(
      members: fn -> [:a@fleet, :b@fleet] end,
      report: fn _node, _opts ->
        {:ok, %{"incompatible" => ["libring:HashRing.Supervisor"]}}
      end
    )
  end

  # ── the split the hot loader already made ────────────────────────────────

  test "a clean, allowlisted candidate takes the direct lane" do
    lane = DeploymentLane.classify(manifest([]), topology: supported_topology())

    assert lane["lane"] == "direct"
    assert lane["reasons"] == []
  end

  test "an off-allowlist module routes a clean candidate to rolling" do
    lane =
      DeploymentLane.classify(manifest([]),
        offending: ["Elixir.OpenAgents.Forge.HotLoader"],
        topology: supported_topology()
      )

    assert lane["lane"] == "rolling"
    assert lane["reasons"] == ["off_allowlist:Elixir.OpenAgents.Forge.HotLoader"]
  end

  test "a structural candidate routes to rolling on its own reasons, whatever the fleet says" do
    lane =
      DeploymentLane.classify(manifest(["config_changed", "migration_added"]),
        topology: supported_topology()
      )

    assert lane["lane"] == "rolling"
    assert lane["reasons"] == ["config_changed", "migration_added"]
    refute Enum.any?(lane["reasons"], &String.starts_with?(&1, "topology"))
  end

  # ── the topology verdict decides the relup lane ──────────────────────────

  test "an application version transition takes the relup lane when the fleet supports it" do
    lane =
      DeploymentLane.classify(manifest(@relup_reasons),
        relup_admitted: true,
        topology: supported_topology()
      )

    assert lane["lane"] == "relup"
    assert lane["topology"]["supported"]
  end

  test "a fleet that cannot support relup never enters the relup lane" do
    lane =
      DeploymentLane.classify(manifest(@relup_reasons),
        relup_admitted: true,
        topology: libring_topology()
      )

    assert lane["lane"] == "rolling"
    assert "topology_incompatible:libring:HashRing.Supervisor" in lane["reasons"]
    refute lane["topology"]["supported"]
  end

  test "the hot loader's own call never reaches the relup lane, because it admits no runner" do
    lane =
      DeploymentLane.classify(manifest(@relup_reasons), topology: supported_topology())

    assert lane["lane"] == "rolling"
    assert "relup_lane_unadmitted" in lane["reasons"]
  end

  # ── the verdict is recorded, and fails closed ────────────────────────────

  test "every classification records the verdict, decisive or not" do
    for reasons <- [[], ["config_changed"], @relup_reasons] do
      lane = DeploymentLane.classify(manifest(reasons), topology: libring_topology())

      assert lane["topology"]["schema"] == "openagents.deployment-lane.topology.v1"
      assert lane["topology"]["nodes"] == 2
      assert lane["topology"]["incompatible"] == ["libring:HashRing.Supervisor"]
    end
  end

  test "an unread verdict refuses relup rather than assuming it" do
    lane = DeploymentLane.classify(manifest(@relup_reasons), relup_admitted: true)

    assert lane["lane"] == "rolling"
    assert "topology_unread" in lane["reasons"]
    refute lane["topology"]["supported"]
  end

  test "a node that cannot be read makes the whole fleet unsupported" do
    topology =
      DeploymentLane.fleet_topology(
        members: fn -> [:a@fleet, :b@fleet] end,
        report: fn
          :a@fleet, _opts -> {:ok, %{"incompatible" => []}}
          :b@fleet, _opts -> :error
        end
      )

    refute topology["supported"]
    assert topology["unreadable"] == 1

    lane =
      DeploymentLane.classify(manifest(@relup_reasons),
        relup_admitted: true,
        topology: topology
      )

    assert lane["lane"] == "rolling"
    assert "topology_unreadable" in lane["reasons"]
  end

  test "a reporting node that raises is unreadable rather than compatible" do
    topology =
      DeploymentLane.fleet_topology(
        members: fn -> [:a@fleet] end,
        report: fn _node, _opts -> {:ok, %{"applications" => 3}} end
      )

    refute topology["supported"]
    assert topology["unreadable"] == 1
  end

  test "an empty fleet is unread, not unanimous" do
    topology = DeploymentLane.fleet_topology(members: fn -> [] end)

    refute topology["supported"]
    assert topology["nodes"] == 0
  end

  test "the verdict names applications and counts nodes, never node names" do
    encoded = Jason.encode!(libring_topology())

    refute encoded =~ "fleet"
    assert encoded =~ "libring"
  end

  # ── this node's own fleet ────────────────────────────────────────────────

  test "the running fleet reports a real verdict, and libring keeps it off relup" do
    topology = DeploymentLane.fleet_topology()

    assert topology["nodes"] >= 1
    assert topology["unreadable"] == 0
    assert "libring:HashRing.Supervisor" in topology["incompatible"]
    refute topology["supported"]

    lane =
      DeploymentLane.classify(manifest(@relup_reasons),
        relup_admitted: true,
        topology: topology
      )

    assert lane["lane"] == "rolling"
  end
end
