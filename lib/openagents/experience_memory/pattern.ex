defmodule OpenAgents.ExperienceMemory.Pattern do
  @moduledoc "Owner-private reusable pattern supported by multiple terminal cases."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  schema "experience_patterns" do
    belongs_to :owner, OpenAgents.Conversations.Visitor, foreign_key: :owner_visitor_id
    belongs_to :scope, OpenAgents.ExperienceMemory.Scope
    field :work_scope, :string
    field :phenomenon, :string
    field :applicability, :string
    field :expected_effect, :string
    field :confidence_millis, :integer
    field :status, :string, default: "active"
    field :digest, :string
    field :generation, :integer
    timestamps()
  end

  def changeset(pattern, attrs),
    do:
      pattern
      |> cast(attrs, [
        :owner_visitor_id,
        :scope_id,
        :work_scope,
        :phenomenon,
        :applicability,
        :expected_effect,
        :confidence_millis,
        :status,
        :digest,
        :generation
      ])
      |> validate_required([
        :owner_visitor_id,
        :scope_id,
        :work_scope,
        :phenomenon,
        :applicability,
        :expected_effect,
        :confidence_millis,
        :status,
        :digest,
        :generation
      ])
      |> validate_inclusion(:status, ~w(active deleted))
      |> validate_format(:digest, ~r/\A[0-9a-f]{64}\z/)
end
