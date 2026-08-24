defmodule OpenAgents.AuditEvent do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "audit_events" do
    field :event_type, :string
    field :actor_type, :string
    field :actor_id, :string
    field :subject_type, :string
    field :subject_id, :string
    field :metadata, :map, default: %{}
    belongs_to :repository, OpenAgents.Repositories.Repository

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_type,
      :actor_type,
      :actor_id,
      :subject_type,
      :subject_id,
      :repository_id,
      :metadata
    ])
    |> validate_required([:event_type, :actor_type, :subject_type, :subject_id, :metadata])
    |> validate_inclusion(:actor_type, OpenAgents.Audit.actor_kinds())
    |> validate_length(:event_type, min: 1, max: 100)
    |> validate_length(:actor_id, max: 200)
    |> validate_length(:subject_type, min: 1, max: 80)
    |> validate_length(:subject_id, min: 1, max: 200)
    |> check_constraint(:actor_type, name: :audit_events_actor_type_allowed)
    |> check_constraint(:metadata, name: :audit_events_metadata_object)
    |> foreign_key_constraint(:repository_id)
  end
end
