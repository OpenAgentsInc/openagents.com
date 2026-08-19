defmodule OpenAgents.Incidents.Incident do
  @moduledoc """
  One durable, owner-scoped record of an anomalous failure.

  An incident is the queryable evidence a failure happened, why (a real
  machine-readable `code`), and what has been done about it. It is written on
  the same transaction that finalizes the failure so it can never be lost, and
  it is visible to its owner exactly like their transcript and receipts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @surfaces ~w(text voice job delegation controller)
  @severities ~w(expected degraded anomalous)
  @statuses ~w(open triaged fixing resolved wont_fix)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "incidents" do
    belongs_to :conversation, OpenAgents.Conversations.Conversation
    belongs_to :owner_user, OpenAgents.Accounts.User
    belongs_to :owner_visitor, OpenAgents.Conversations.Visitor
    belongs_to :fixer_job, OpenAgents.Work.Job

    field :surface, :string
    field :origin, :string
    field :correlation_ref, :string
    field :code, :string
    field :severity, :string, default: "anomalous"
    field :summary, :string
    field :context, :map, default: %{}
    field :status, :string, default: "open"
    field :receipt_ref, :string
    timestamps()
  end

  @castable [
    :conversation_id,
    :owner_user_id,
    :owner_visitor_id,
    :fixer_job_id,
    :surface,
    :origin,
    :correlation_ref,
    :code,
    :severity,
    :summary,
    :context,
    :status,
    :receipt_ref
  ]

  def changeset(incident, attributes) do
    incident
    |> cast(attributes, @castable)
    |> validate_required([:surface, :origin, :code, :severity, :status])
    |> validate_inclusion(:surface, @surfaces)
    |> validate_inclusion(:severity, @severities)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:code, max: 128)
    |> validate_length(:origin, max: 64)
    |> validate_length(:correlation_ref, max: 128)
    |> validate_length(:summary, max: 500)
    |> validate_length(:receipt_ref, max: 256)
  end

  def surfaces, do: @surfaces
  def severities, do: @severities
  def statuses, do: @statuses
end
