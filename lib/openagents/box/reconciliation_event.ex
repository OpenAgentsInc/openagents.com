defmodule OpenAgents.Box.ReconciliationEvent do
  @moduledoc "Durable evidence emitted by Box lifecycle reconciliation."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "box_reconciliation_events" do
    field :provider_box_id, :string
    field :event_type, :string
    field :reason, :string
    field :details, :map, default: %{}
    field :observed_at, :utc_datetime_usec
    field :handled_at, :utc_datetime_usec
    timestamps()
  end
end
