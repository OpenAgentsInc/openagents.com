defmodule OpenAgents.Roles.SelectionInput do
  @moduledoc "Typed host input for selecting one admitted Sarah role program."

  @enforce_keys [:surface, :authority, :available_capabilities]
  defstruct [:requested_role_id, :surface, :authority, :available_capabilities]

  @type t :: %__MODULE__{
          requested_role_id: String.t() | nil,
          surface: String.t(),
          authority: String.t(),
          available_capabilities: [String.t()]
        }
end
