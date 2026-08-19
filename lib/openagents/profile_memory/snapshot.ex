defmodule OpenAgents.ProfileMemory.Snapshot do
  @moduledoc "Frozen generation and time boundary for one account profile plane."

  @enforce_keys [:owner_visitor_id, :generation, :captured_at, :ref]
  defstruct [:owner_visitor_id, :generation, :captured_at, :ref]

  @type t :: %__MODULE__{
          owner_visitor_id: Ecto.UUID.t(),
          generation: non_neg_integer(),
          captured_at: DateTime.t(),
          ref: String.t()
        }
end
