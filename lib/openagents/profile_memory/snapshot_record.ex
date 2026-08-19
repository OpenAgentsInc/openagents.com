defmodule OpenAgents.ProfileMemory.SnapshotRecord do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "profile_memory_snapshots" do
    field :owner_visitor_id, :binary_id
    timestamps()
  end
end
