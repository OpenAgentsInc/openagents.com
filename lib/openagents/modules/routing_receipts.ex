defmodule OpenAgents.Modules.RoutingReceipts do
  @moduledoc "Durably records a routing decision before any selected module dispatch."

  alias OpenAgents.Modules.{RouteDecision, RouteReceipt}
  alias OpenAgents.Repo

  @spec persist(Ecto.UUID.t(), String.t(), RouteDecision.t()) ::
          {:ok, RouteReceipt.t()} | {:error, Ecto.Changeset.t() | atom()}
  def persist(turn_receipt_id, provider_call_id, %RouteDecision{} = decision) do
    attributes = %{
      turn_receipt_id: turn_receipt_id,
      provider_call_id: provider_call_id,
      status: decision.status,
      reason: decision.reason,
      intent_digest: decision.intent_digest,
      registry_digest: decision.registry_digest,
      policy_id: decision.policy_id,
      policy_digest: decision.policy_digest,
      required_capability: decision.required_capability,
      required_side_effect: decision.required_side_effect,
      surface: decision.surface,
      selected: decision.selected,
      proposed: decision.proposed,
      rejected: decision.rejected,
      program_artifact: decision.program_artifact,
      fallback: decision.fallback,
      degraded: decision.degraded
    }

    case Repo.get_by(RouteReceipt,
           turn_receipt_id: turn_receipt_id,
           provider_call_id: provider_call_id
         ) do
      nil ->
        %RouteReceipt{}
        |> RouteReceipt.create_changeset(attributes)
        |> Repo.insert()

      %RouteReceipt{} = existing ->
        if same_decision?(existing, attributes),
          do: {:ok, existing},
          else: {:error, :route_receipt_conflict}
    end
  end

  defp same_decision?(receipt, attributes) do
    Enum.all?(
      [
        :status,
        :reason,
        :intent_digest,
        :registry_digest,
        :policy_id,
        :policy_digest,
        :required_capability,
        :required_side_effect,
        :surface,
        :selected,
        :proposed,
        :rejected,
        :program_artifact,
        :fallback,
        :degraded
      ],
      &(Map.get(receipt, &1) == Map.get(attributes, &1))
    )
  end
end
