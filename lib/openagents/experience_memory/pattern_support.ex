defmodule OpenAgents.ExperienceMemory.PatternSupport do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  @foreign_key_type :binary_id
  schema "experience_pattern_supports" do
    belongs_to :pattern, OpenAgents.ExperienceMemory.Pattern, primary_key: true
    belongs_to :record, OpenAgents.ExperienceMemory.Record, primary_key: true
    field :outcome_state, :string
  end

  def changeset(support, attrs),
    do:
      support
      |> cast(attrs, [:pattern_id, :record_id, :outcome_state])
      |> validate_required([:pattern_id, :record_id, :outcome_state])
      |> validate_inclusion(:outcome_state, ~w(succeeded failed))
end
