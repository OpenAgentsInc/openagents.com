defmodule OpenAgents.SCV.ExecutionEvent do
  @moduledoc "One bounded, credential-free event retained for an SCV run."

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.SCV.Execution

  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "scv_run_events" do
    belongs_to :run, Execution, type: :binary_id
    field :schema, :string, default: "openagents.scv.event.v1"
    field :event_type, :string
    field :payload, :map
    field :emitted_at, :utc_datetime_usec
    timestamps()
  end

  @doc false
  def changeset(event, attributes) do
    event
    |> cast(attributes, [:run_id, :schema, :event_type, :payload, :emitted_at])
    |> validate_required([:run_id, :schema, :event_type, :payload, :emitted_at])
    |> validate_length(:event_type, min: 1, max: 80)
    |> foreign_key_constraint(:run_id)
    |> check_constraint(:schema, name: :scv_run_events_schema_check)
    |> check_constraint(:payload, name: :scv_run_events_payload_bound_check)
  end
end
