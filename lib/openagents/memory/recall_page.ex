defmodule OpenAgents.Memory.RecallPage do
  @moduledoc "Bounded deterministic recall page with ranking/degradation evidence."

  @enforce_keys [:matches, :truncated]
  defstruct @enforce_keys ++
              [strategy: "lexical", semantic_degraded: false, semantic_reason: nil]

  @type t :: %__MODULE__{
          matches: [OpenAgents.Memory.RecallMatch.t()],
          truncated: boolean(),
          strategy: String.t(),
          semantic_degraded: boolean(),
          semantic_reason: String.t() | nil
        }
end
