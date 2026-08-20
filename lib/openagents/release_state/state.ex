defmodule OpenAgents.ReleaseState.State do
  @moduledoc "Versioned state retained by `OpenAgents.ReleaseState` across relups."

  @enforce_keys [:schema_version, :observations]
  defstruct [:schema_version, :observations, :integrity]

  @type t :: %__MODULE__{
          schema_version: 1 | 2,
          observations: [term()],
          integrity: binary() | nil
        }
end
