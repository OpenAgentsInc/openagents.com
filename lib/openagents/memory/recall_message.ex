defmodule OpenAgents.Memory.RecallMessage do
  @moduledoc "Exact source message admitted to a bounded recall neighborhood."

  @enforce_keys [:source_ref, :role, :observed_at, :content]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source_ref: String.t(),
          role: String.t(),
          observed_at: DateTime.t(),
          content: String.t()
        }
end
