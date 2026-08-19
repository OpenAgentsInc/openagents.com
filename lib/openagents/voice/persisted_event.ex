defmodule OpenAgents.Voice.PersistedEvent do
  @moduledoc "Bounded provider-neutral event committed under one voice generation."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "voice_events" do
    belongs_to :voice_session, OpenAgents.Voice.Session
    field :generation, :integer
    field :sequence, :integer
    field :provider_event_id, :string
    field :kind, :string
    field :payload, :map, default: %{}
    field :observed_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end

  def create_changeset(event, attributes) do
    event
    |> cast(attributes, [
      :voice_session_id,
      :generation,
      :sequence,
      :provider_event_id,
      :kind,
      :payload,
      :observed_at
    ])
    |> validate_required([
      :voice_session_id,
      :generation,
      :sequence,
      :kind,
      :payload,
      :observed_at
    ])
    |> validate_number(:generation, greater_than: 0)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_length(:provider_event_id, max: 256)
    |> validate_length(:kind, max: 128)
    |> foreign_key_constraint(:voice_session_id)
    |> unique_constraint([:voice_session_id, :sequence])
    |> unique_constraint([:voice_session_id, :generation, :provider_event_id],
      name: :voice_events_provider_event_id_index
    )
  end
end
