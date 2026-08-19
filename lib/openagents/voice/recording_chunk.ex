defmodule OpenAgents.Voice.RecordingChunk do
  @moduledoc """
  One ordered slice of a call recording.

  A WebM/Opus (or fragmented MP4) stream is only playable as the ordered
  concatenation of its slices: every chunk after the first depends on the header
  in the first. So `sequence` is not a convenience — a chunk served on its own,
  or served out of order, is not media. `OpenAgents.Voice.Recordings.stream/1` is the
  only sanctioned reader.

  `data` holds the sealed ciphertext when a recording key is configured
  (`OpenAgents.Voice.RecordingVault`), and the raw slice when it is not. The parent
  recording's `sealed` flag says which, so a key rotation cannot silently
  reinterpret old rows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "voice_recording_chunks" do
    belongs_to :recording, OpenAgents.Voice.Recording, foreign_key: :voice_recording_id
    field :sequence, :integer
    field :data, :binary, redact: true
    field :byte_size, :integer
    field :observed_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  def create_changeset(chunk, attributes) do
    chunk
    |> cast(attributes, [:voice_recording_id, :sequence, :data, :byte_size, :observed_at])
    |> validate_required([:voice_recording_id, :sequence, :data, :byte_size, :observed_at])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_number(:byte_size, greater_than: 0)
    |> foreign_key_constraint(:voice_recording_id)
    |> unique_constraint([:voice_recording_id, :sequence])
  end
end
