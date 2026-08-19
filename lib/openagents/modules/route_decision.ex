defmodule OpenAgents.Modules.RouteDecision do
  @moduledoc "Reproducible result of one policy-aware module routing decision."

  @enforce_keys [
    :schema,
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
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}
end
