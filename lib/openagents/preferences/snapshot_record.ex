defmodule OpenAgents.Preferences.SnapshotRecord do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "preference_snapshots" do
    belongs_to :owner, OpenAgents.Conversations.Visitor, foreign_key: :owner_visitor_id
    field :scope_generation, :integer
    field :captured_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(snapshot, attributes) do
    snapshot
    |> cast(attributes, [:owner_visitor_id, :scope_generation, :captured_at, :inserted_at])
    |> validate_required([:owner_visitor_id, :scope_generation, :captured_at, :inserted_at])
    |> validate_number(:scope_generation, greater_than_or_equal_to: 0)
  end
end
