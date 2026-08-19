defmodule OpenAgents.ExperienceMemory.Scope do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  schema "experience_scopes" do
    belongs_to :owner, OpenAgents.Conversations.Visitor, foreign_key: :owner_visitor_id
    field :work_scope, :string
    field :generation, :integer, default: 0
    timestamps()
  end

  def changeset(scope, attrs),
    do:
      scope
      |> cast(attrs, [:owner_visitor_id, :work_scope, :generation])
      |> validate_required([:owner_visitor_id, :work_scope, :generation])
end
