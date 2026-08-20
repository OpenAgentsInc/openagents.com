defmodule OpenAgents.Modules.RouterTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Modules.{Router, RoutingPolicy, SurfacePolicy}
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Tools.Registry

  test "identical intent, policy, and catalog select the same deterministic baseline" do
    snapshot = Registry.current!()
    policy = RoutingPolicy.default()
    input = input()

    assert {:ok, first} = Router.route(snapshot, policy, input)
    assert {:ok, second} = Router.route(snapshot, policy, input)
    assert first == second
    assert first.status == "selected"
    assert first.selected["registry_digest"] == snapshot.digest
    assert first.reason == "deterministic_baseline_selected"
  end

  test "an exact admitted proposal is revalidated and restrictive policy cannot be weakened" do
    snapshot = Registry.current!()
    artifact = Map.fetch!(snapshot.modules, {"sarah.tool.conversation_read.v1", 1})
    proposal = reference(artifact, snapshot.digest)
    policy = RoutingPolicy.default()

    assert {:ok, selected} =
             Router.route(
               snapshot,
               policy,
               Map.merge(input(), %{proposal: proposal, exact_proposal: true})
             )

    assert selected.selected == proposal
    assert {:ok, ^artifact} = Router.revalidate(selected, snapshot, policy, input())

    assert {:ok, strict_policy} =
             RoutingPolicy.new(%{allowed_residencies: ["user_device_only"]})

    assert {:ok, refused} =
             Router.route(
               snapshot,
               strict_policy,
               Map.merge(input(), %{proposal: proposal, exact_proposal: true})
             )

    assert refused.status == "refused"
    assert refused.selected == nil
    assert Enum.any?(refused.rejected, &("residency_refused" in &1["reasons"]))
  end

  test "missing authority yields unavailable rather than an unauthorized fallback" do
    snapshot = Registry.current!()
    policy = RoutingPolicy.default()
    no_authority = %{input() | authorities: MapSet.new()}

    assert {:ok, decision} = Router.route(snapshot, policy, no_authority)
    assert decision.status == "refused"
    assert decision.selected == nil
    assert Enum.all?(decision.rejected, &("authority_refused" in &1["reasons"]))

    assert {:error, :module_route_unavailable} =
             Router.revalidate(decision, snapshot, policy, no_authority)
  end

  test "every restrictive policy axis is a hard filter before ranking" do
    snapshot = Registry.current!()
    artifact = Map.fetch!(snapshot.modules, {"sarah.tool.conversation_read.v1", 1})
    proposal = reference(artifact, snapshot.digest)
    exact_input = Map.merge(input(), %{proposal: proposal, exact_proposal: true})

    matrix = [
      {:allowed_publishers, ["DifferentPublisher"], "publisher_refused"},
      {:allowed_costs, ["paid"], "cost_refused"},
      {:allowed_qualities, ["unreviewed"], "quality_refused"},
      {:allowed_privacy, ["user_device_only"], "privacy_refused"},
      {:allowed_residencies, ["user_device_only"], "residency_refused"},
      {:allowed_jurisdictions, ["eu_only"], "jurisdiction_refused"},
      {:allowed_censorship_resistance, ["required"], "censorship_resistance_refused"},
      {:allowed_approval_classes, ["explicit_operator_approval"], "approval_class_refused"},
      {:allowed_side_effects, ["reversible_write"], "side_effect_policy_refused"}
    ]

    Enum.each(matrix, fn {field, value, reason} ->
      assert {:ok, policy} = RoutingPolicy.new(%{field => value})
      assert {:ok, decision} = Router.route(snapshot, policy, exact_input)
      assert decision.status == "refused"
      assert Enum.any?(decision.rejected, &(reason in &1["reasons"]))
    end)

    costly = %{artifact | facets: Map.put(artifact.facets, "cost_units", 1)}
    costly = %{costly | artifact_digest: OpenAgents.Modules.Artifact.artifact_digest(costly)}

    costly_snapshot = %{
      snapshot
      | modules: Map.put(snapshot.modules, {costly.module_id, 1}, costly)
    }

    costly_input =
      Map.merge(input(), %{proposal: reference(costly, snapshot.digest), exact_proposal: true})

    assert {:ok, decision} = Router.route(costly_snapshot, RoutingPolicy.default(), costly_input)
    assert decision.status == "refused"
    assert Enum.any?(decision.rejected, &("budget_refused" in &1["reasons"]))
  end

  test "stale catalog and policy proposals fail immediate revalidation" do
    snapshot = Registry.current!()
    policy = RoutingPolicy.default()
    assert {:ok, decision} = Router.route(snapshot, policy, input())

    stale_snapshot = %{snapshot | digest: String.duplicate("0", 64)}

    assert {:error, :stale_module_registry} =
             Router.revalidate(decision, stale_snapshot, policy, input())

    assert {:ok, changed_policy} =
             RoutingPolicy.new(%{id: "sarah.routing.policy.changed.v1"})

    assert {:error, :stale_routing_policy} =
             Router.revalidate(decision, snapshot, changed_policy, input())

    assert {:error, :stale_module_surface} =
             Router.revalidate(decision, snapshot, policy, %{input() | surface: "voice"})
  end

  test "surface contracts are finite and search cannot admit effectful executors" do
    assert SurfacePolicy.surfaces() ==
             ~w(agent computer mcp repository search text voice)

    assert SurfacePolicy.contracts()["search"].effects == ["read_only"]
    assert "agent_executor" in SurfacePolicy.contracts()["computer"].kinds
    assert "plugin" in SurfacePolicy.contracts()["repository"].kinds
  end

  test "a rejected optional program proposal degrades to the stable baseline with provenance" do
    snapshot = Registry.current!()
    policy = RoutingPolicy.default()

    stale_proposal = %{
      "module_id" => "sarah.tool.missing",
      "version" => 1,
      "artifact_digest" => String.duplicate("b", 64),
      "registry_digest" => snapshot.digest
    }

    route_input =
      input()
      |> Map.put(:proposal, stale_proposal)
      |> Map.put(:program_degraded, true)

    assert {:ok, decision} = Router.route(snapshot, policy, route_input)
    assert decision.status == "selected"
    assert decision.fallback
    assert decision.degraded
    assert decision.program_artifact == nil
    assert decision.reason == "deterministic_baseline_selected"
  end

  test "machine-effect modules route under the paired-machine policy but not the default" do
    snapshot = Registry.current!()
    artifact = Map.fetch!(snapshot.modules, {"sarah.tool.computer_run.v1", 1})
    proposal = reference(artifact, snapshot.digest)

    machine_input =
      Map.merge(input(), %{
        required_capability: "computer.control",
        required_side_effect: "external_effect",
        authorities: MapSet.new(["computer.control"]),
        proposal: proposal,
        exact_proposal: true
      })

    assert {:ok, refused} = Router.route(snapshot, RoutingPolicy.default(), machine_input)
    assert refused.status == "refused"
    assert refused.selected == nil

    assert Enum.any?(
             refused.rejected,
             &("approval_class_refused" in &1["reasons"] or
                 "side_effect_policy_refused" in &1["reasons"])
           )

    assert {:ok, selected} =
             Router.route(snapshot, RoutingPolicy.paired_machine(), machine_input)

    assert selected.status == "selected"
    assert selected.selected == proposal
  end

  test "an unadmitted routing program identity is rejected before it can propose" do
    snapshot = Registry.current!()

    input =
      input()
      |> Map.put(:program_artifact, %{
        "artifact_id" => "unadmitted.routing.program",
        "artifact_digest" => String.duplicate("a", 64)
      })

    assert {:error, :module_route_program_invalid} =
             Router.route(snapshot, RoutingPolicy.default(), input)
  end

  defp input do
    %{
      intent_digest: Canonical.sha256("find the exact source"),
      required_capability: "conversation.read",
      required_side_effect: "read_only",
      surface: "text",
      data_scope: "browser_conversation",
      authorities: MapSet.new(["conversation.read"])
    }
  end

  defp reference(artifact, registry_digest) do
    %{
      "module_id" => artifact.module_id,
      "version" => artifact.version,
      "artifact_digest" => artifact.artifact_digest,
      "registry_digest" => registry_digest
    }
  end
end
