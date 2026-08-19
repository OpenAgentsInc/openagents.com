defmodule OpenAgents.Voice.ClientEvent do
  @moduledoc "Bounded, content-free browser observation for voice service indicators."

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(peer_connected first_remote_track playback_started peer_disconnected interrupt_acknowledged client_failed client_ended)
  @browsers ~w(chrome safari firefox edge other)
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "voice_client_events" do
    belongs_to :voice_session, OpenAgents.Voice.Session
    field :generation, :integer
    field :sequence, :integer
    field :kind, :string
    field :browser_family, :string
    field :browser_major, :integer
    field :observed_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end

  def create_changeset(event, attributes) do
    event
    |> cast(attributes, [
      :voice_session_id,
      :generation,
      :sequence,
      :kind,
      :browser_family,
      :browser_major,
      :observed_at
    ])
    |> validate_required([
      :voice_session_id,
      :generation,
      :sequence,
      :kind,
      :browser_family,
      :observed_at
    ])
    |> validate_number(:sequence, greater_than: 0, less_than_or_equal_to: 64)
    |> validate_number(:generation, greater_than: 0)
    |> validate_number(:browser_major, greater_than: 0, less_than_or_equal_to: 1000)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:browser_family, @browsers)
    |> foreign_key_constraint(:voice_session_id)
    |> unique_constraint([:voice_session_id, :generation, :sequence])
  end
end
