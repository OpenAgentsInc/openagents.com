defmodule OpenAgents.Context do
  @moduledoc "Immutable provider context composed for one Sarah inference."

  @enforce_keys [
    :instructions,
    :instruction_digest,
    :persona_id,
    :persona_digest,
    :role_id,
    :role_digest,
    :role_selection,
    :applied_preferences,
    :applied_experiences,
    :blueprint_revision,
    :blueprint_digest
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          instructions: String.t(),
          instruction_digest: String.t(),
          persona_id: String.t(),
          persona_digest: String.t(),
          role_id: String.t(),
          role_digest: String.t(),
          role_selection: map(),
          applied_preferences: [map()],
          applied_experiences: map(),
          blueprint_revision: String.t() | nil,
          blueprint_digest: String.t() | nil
        }
end
