defmodule OpenAgents.Preferences.Scope do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:owner_visitor_id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "preference_scopes" do
    field :generation, :integer, default: 0
    timestamps()
  end

  def changeset(scope, attributes) do
    scope
    |> cast(attributes, [:owner_visitor_id, :generation])
    |> validate_required([:owner_visitor_id, :generation])
    |> validate_number(:generation, greater_than_or_equal_to: 0)
  end
end
