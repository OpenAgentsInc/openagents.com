defmodule OpenAgents.Roles.Role do
  @moduledoc "Immutable role-program fragment composed below Sarah's core identity."

  @enforce_keys [
    :id,
    :version,
    :status,
    :content,
    :digest,
    :source_ref,
    :source_digest,
    :compatibility_min,
    :compatibility_max,
    :surfaces,
    :required_capabilities,
    :register
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer(),
          status: String.t(),
          content: String.t(),
          digest: String.t(),
          source_ref: String.t(),
          source_digest: String.t(),
          compatibility_min: pos_integer(),
          compatibility_max: pos_integer(),
          surfaces: [String.t()],
          required_capabilities: [String.t()],
          register: String.t()
        }

  @callback artifact() :: t()
end
