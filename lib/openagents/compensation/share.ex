defmodule OpenAgents.Compensation.Share do
  @moduledoc "Deterministic contributor allocation for one compensation event."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "compensation_shares" do
    belongs_to :event, OpenAgents.Compensation.Event
    field :contribution_ref, :string
    field :allocation_ppm, :integer
    field :allocated_units, :integer
    field :share_digest, :string
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(record, attributes) do
    record
    |> cast(
      attributes,
      ~w(event_id contribution_ref allocation_ppm allocated_units share_digest)a
    )
    |> validate_required(
      ~w(event_id contribution_ref allocation_ppm allocated_units share_digest)a
    )
    |> validate_number(:allocation_ppm, greater_than: 0, less_than_or_equal_to: 1_000_000)
    |> validate_number(:allocated_units, greater_than_or_equal_to: 0)
    |> validate_format(:share_digest, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:event_id)
    |> unique_constraint([:event_id, :contribution_ref])
  end
end
