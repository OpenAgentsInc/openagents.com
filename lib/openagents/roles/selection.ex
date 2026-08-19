defmodule OpenAgents.Roles.Selection do
  @moduledoc "Immutable explanation of one host role-program selection."

  @enforce_keys [
    :role,
    :surface,
    :authority,
    :requested_role_id,
    :available_capabilities,
    :reason,
    :input_digest,
    :catalog_digest
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          role: OpenAgents.Roles.Role.t(),
          surface: String.t(),
          authority: String.t(),
          requested_role_id: String.t() | nil,
          available_capabilities: [String.t()],
          reason: String.t(),
          input_digest: String.t(),
          catalog_digest: String.t()
        }

  def receipt(%__MODULE__{} = selection) do
    %{
      "schema" => "sarah.role_selection.v1",
      "role_id" => selection.role.id,
      "role_digest" => selection.role.digest,
      "surface" => selection.surface,
      "authority" => selection.authority,
      "requested_role_id" => selection.requested_role_id,
      "available_capabilities" => selection.available_capabilities,
      "reason" => selection.reason,
      "input_digest" => selection.input_digest,
      "catalog_digest" => selection.catalog_digest
    }
  end
end
