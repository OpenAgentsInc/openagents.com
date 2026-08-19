defmodule OpenAgents.Context do
  @moduledoc false

  defstruct [
    :persona_id,
    :persona_digest,
    :role_id,
    :role_digest,
    :role_selection,
    :instruction_digest,
    :blueprint_revision,
    :blueprint_digest,
    :applied_preferences,
    :applied_experiences
  ]
end
