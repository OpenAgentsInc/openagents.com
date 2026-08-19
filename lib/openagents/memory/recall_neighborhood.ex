defmodule OpenAgents.Memory.RecallNeighborhood do
  @moduledoc "Bounded ordered context around one exact recall source."

  @enforce_keys [:source_ref, :messages, :before_truncated, :after_truncated]
  defstruct @enforce_keys ++ [source_step: nil]

  @type t :: %__MODULE__{
          source_ref: String.t(),
          messages: [OpenAgents.Memory.RecallMessage.t()],
          before_truncated: boolean(),
          after_truncated: boolean(),
          source_step: map() | nil
        }
end
