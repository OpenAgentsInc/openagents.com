defmodule OpenAgents.Modules.Router do
  @moduledoc "Deterministic policy filter and proposal revalidator over one captured registry."

  alias OpenAgents.Modules.{Artifact, Discovery, RouteDecision, RoutingPolicy}
  alias OpenAgents.Observability
  alias OpenAgents.Tools.Snapshot

  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @spec route(Snapshot.t(), RoutingPolicy.t(), map()) ::
          {:ok, RouteDecision.t()} | {:error, atom()}
  def route(%Snapshot{} = snapshot, %RoutingPolicy{} = policy, input) when is_map(input) do
    with :ok <- RoutingPolicy.validate(policy),
         :ok <- validate_input(input),
         candidates <- candidates(snapshot, input),
         {eligible, rejected} <- partition(candidates, policy, input),
         {:ok, selected, reason, fallback} <- select(snapshot, eligible, input) do
      status =
        cond do
          selected -> "selected"
          rejected != [] -> "refused"
          true -> "unavailable"
        end

      decision = %RouteDecision{
        schema: "sarah.module_route_decision.v1",
        status: status,
        reason: reason,
        intent_digest: input.intent_digest,
        registry_digest: snapshot.digest,
        policy_id: policy.id,
        policy_digest: policy.digest,
        required_capability: input.required_capability,
        required_side_effect: input.required_side_effect,
        surface: input.surface,
        selected: selected,
        proposed: Map.get(input, :proposal),
        rejected: Enum.take(rejected, 64),
        program_artifact: Map.get(input, :program_artifact),
        fallback: fallback,
        degraded: Map.get(input, :program_degraded, false)
      }

      _telemetry_result = Observability.module_route(decision)
      {:ok, decision}
    end
  end

  def route(%Snapshot{}, %RoutingPolicy{}, _input), do: {:error, :module_route_input_invalid}

  @spec revalidate(RouteDecision.t(), Snapshot.t(), RoutingPolicy.t(), map()) ::
          {:ok, Artifact.t()} | {:error, atom()}
  def revalidate(
        %RouteDecision{selected: selected} = decision,
        %Snapshot{} = snapshot,
        %RoutingPolicy{} = policy,
        context
      )
      when is_map(context) do
    cond do
      is_nil(selected) ->
        {:error, :module_route_unavailable}

      decision.registry_digest != snapshot.digest ->
        {:error, :stale_module_registry}

      decision.policy_digest != policy.digest ->
        {:error, :stale_routing_policy}

      decision.surface != context.surface ->
        {:error, :stale_module_surface}

      true ->
        with {:ok, artifact} <- Discovery.revalidate(snapshot, selected),
             [] <- rejection_reasons(artifact, policy, context) do
          {:ok, artifact}
        else
          [_reason | _rest] -> {:error, :module_policy_refused}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp candidates(snapshot, %{proposal: proposal, exact_proposal: true}) when is_map(proposal) do
    case Discovery.revalidate(snapshot, proposal) do
      {:ok, artifact} -> [artifact]
      {:error, _reason} -> []
    end
  end

  defp candidates(_snapshot, %{exact_proposal: true}), do: []

  defp candidates(snapshot, _input),
    do: snapshot.modules |> Map.values() |> Enum.filter(&Artifact.executable?/1)

  defp partition(candidates, policy, input) do
    candidates
    |> Enum.sort_by(&{&1.module_id, &1.version, &1.artifact_digest})
    |> Enum.reduce({[], []}, fn artifact, {eligible, rejected} ->
      case rejection_reasons(artifact, policy, input) do
        [] -> {[artifact | eligible], rejected}
        reasons -> {eligible, [rejection(artifact, reasons) | rejected]}
      end
    end)
    |> then(fn {eligible, rejected} -> {Enum.reverse(eligible), Enum.reverse(rejected)} end)
  end

  defp select(snapshot, eligible, input) do
    proposal = Map.get(input, :proposal)

    proposed =
      if is_map(proposal) do
        Enum.find(eligible, fn artifact ->
          artifact.module_id == proposal["module_id"] and artifact.version == proposal["version"] and
            artifact.artifact_digest == proposal["artifact_digest"] and
            snapshot.digest == proposal["registry_digest"]
        end)
      end

    cond do
      proposed ->
        {:ok, reference(proposed, snapshot.digest), "admitted_proposal_selected", false}

      Map.get(input, :exact_proposal, false) ->
        {:ok, nil, "exact_proposal_unavailable_or_refused", false}

      eligible == [] ->
        {:ok, nil, "no_policy_eligible_module", not is_nil(proposal)}

      true ->
        selected = Enum.min_by(eligible, &baseline_rank/1)

        {:ok, reference(selected, snapshot.digest), "deterministic_baseline_selected",
         not is_nil(proposal)}
    end
  end

  defp rejection_reasons(artifact, policy, input) do
    []
    |> reject_unless(
      input.required_capability in artifact.capability_scopes,
      "capability_mismatch"
    )
    |> reject_unless(
      OpenAgents.Modules.SurfacePolicy.authorize_route(artifact, input.surface) == :ok,
      "surface_refused"
    )
    |> reject_unless(
      artifact.side_effect_class == input.required_side_effect,
      "side_effect_mismatch"
    )
    |> reject_unless(artifact.publisher in policy.allowed_publishers, "publisher_refused")
    |> reject_unless(artifact.facets["cost"] in policy.allowed_costs, "cost_refused")
    |> reject_unless(
      is_integer(artifact.facets["cost_units"]) and
        artifact.facets["cost_units"] <= policy.maximum_cost_units,
      "budget_refused"
    )
    |> reject_unless(artifact.facets["quality"] in policy.allowed_qualities, "quality_refused")
    |> reject_unless(artifact.facets["privacy"] in policy.allowed_privacy, "privacy_refused")
    |> reject_unless(
      artifact.facets["residency"] in policy.allowed_residencies,
      "residency_refused"
    )
    |> reject_unless(
      artifact.facets["jurisdiction"] in policy.allowed_jurisdictions,
      "jurisdiction_refused"
    )
    |> reject_unless(
      artifact.facets["censorship_resistance"] in policy.allowed_censorship_resistance,
      "censorship_resistance_refused"
    )
    |> reject_unless(
      artifact.approval_class in policy.allowed_approval_classes,
      "approval_class_refused"
    )
    |> reject_unless(
      artifact.side_effect_class in policy.allowed_side_effects,
      "side_effect_policy_refused"
    )
    |> reject_unless(
      policy.runtime_version >= artifact.compatibility["runtime_min"] and
        policy.runtime_version <= artifact.compatibility["runtime_max"],
      "runtime_incompatible"
    )
    |> reject_unless(
      input.data_scope in artifact.data_scopes,
      "data_scope_refused"
    )
    |> reject_unless(
      MapSet.member?(input.authorities, input.required_capability),
      "authority_refused"
    )
  end

  defp reject_unless(reasons, true, _reason), do: reasons
  defp reject_unless(reasons, false, reason), do: reasons ++ [reason]

  defp rejection(artifact, reasons),
    do: %{
      "module_id" => artifact.module_id,
      "version" => artifact.version,
      "artifact_digest" => artifact.artifact_digest,
      "reasons" => reasons
    }

  defp reference(artifact, registry_digest),
    do: %{
      "module_id" => artifact.module_id,
      "version" => artifact.version,
      "artifact_digest" => artifact.artifact_digest,
      "registry_digest" => registry_digest
    }

  defp baseline_rank(artifact),
    do: {
      quality_rank(artifact.facets["quality"]),
      cost_rank(artifact.facets["cost"]),
      artifact.module_id,
      artifact.version,
      artifact.artifact_digest
    }

  defp quality_rank("host_validated"), do: 0
  defp quality_rank(_quality), do: 1
  defp cost_rank("included_first_party"), do: 0
  defp cost_rank(_cost), do: 1

  defp validate_input(input) do
    cond do
      not valid_digest?(input[:intent_digest]) ->
        {:error, :module_route_intent_invalid}

      not bounded?(input[:required_capability], 128) ->
        {:error, :module_route_capability_invalid}

      input[:required_side_effect] not in ~w(read_only reversible_write external_effect) ->
        {:error, :module_route_side_effect_invalid}

      not bounded?(input[:data_scope], 128) ->
        {:error, :module_route_scope_invalid}

      input[:surface] not in OpenAgents.Modules.SurfacePolicy.surfaces() ->
        {:error, :module_route_surface_invalid}

      not match?(%MapSet{}, input[:authorities]) ->
        {:error, :module_route_authorities_invalid}

      Map.has_key?(input, :proposal) and not is_map(input.proposal) ->
        {:error, :module_route_proposal_invalid}

      Map.has_key?(input, :program_artifact) and not valid_program_ref?(input.program_artifact) ->
        {:error, :module_route_program_invalid}

      true ->
        :ok
    end
  end

  defp valid_program_ref?(nil), do: true

  defp valid_program_ref?(%{"artifact_id" => id, "artifact_digest" => digest}) do
    with true <- bounded?(id, 256) and valid_digest?(digest),
         catalog when is_map(catalog) <- OpenAgents.ProgramArtifacts.current!(),
         {:ok, artifact} <- Map.fetch(catalog.by_id, id) do
      artifact.digest == digest and artifact.signature_id == "sarah.module.route.v1"
    else
      _not_admitted -> false
    end
  end

  defp valid_program_ref?(_reference), do: false

  defp valid_digest?(value), do: is_binary(value) and Regex.match?(@digest_regex, value)
  defp bounded?(value, maximum), do: is_binary(value) and byte_size(value) in 1..maximum
end
