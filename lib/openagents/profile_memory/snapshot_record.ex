defmodule OpenAgents.ProfileMemory.SnapshotRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "profile_memory_snapshots" do
    belongs_to :owner_visitor, OpenAgents.Conversations.Visitor
    field :scope_generation, :integer
    field :captured_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(snapshot, attributes) do
    snapshot
    |> cast(attributes, [:owner_visitor_id, :scope_generation, :captured_at, :inserted_at])
    |> validate_required([:owner_visitor_id, :scope_generation, :captured_at, :inserted_at])
    |> validate_number(:scope_generation, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:owner_visitor_id)
  end
end
