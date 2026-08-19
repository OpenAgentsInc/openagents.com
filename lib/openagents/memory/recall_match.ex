defmodule OpenAgents.Memory.RecallMatch do
  @moduledoc "Bounded lexical discovery result; not the full source message."

  @enforce_keys [:source_ref, :role, :observed_at, :excerpt, :score, :rank, :truncated]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source_ref: String.t(),
          role: String.t(),
          observed_at: DateTime.t(),
          excerpt: String.t(),
          score: float(),
          rank: pos_integer(),
          truncated: boolean()
        }
end
