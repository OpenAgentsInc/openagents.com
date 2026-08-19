defmodule OpenAgents.ProfileMemory.Scope do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "profile_memory_scopes" do
    belongs_to :owner_visitor, OpenAgents.Conversations.Visitor, primary_key: true
    field :generation, :integer, default: 0
    timestamps()
  end

  def changeset(scope, attributes) do
    scope
    |> cast(attributes, [:owner_visitor_id, :generation])
    |> validate_required([:owner_visitor_id, :generation])
    |> validate_number(:generation, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:owner_visitor_id)
  end
end
