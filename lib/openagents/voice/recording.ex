defmodule OpenAgents.Voice.Recording do
  @moduledoc """
  One recorded audio artifact for one fenced voice generation.

  The bytes are browser-supplied evidence, never authority (`INVARIANTS.md`
  VOICE-012). `voice_transcript_items` remains the conversation record; this row
  says what audio a browser managed to upload for a call, and `status` says how
  complete that upload is:

    * `recording` — open, chunks may still arrive
    * `complete` — the browser finalized it
    * `truncated` — a ceiling was reached and later chunks were refused
    * `aborted` — the call ended without a finalize (tab closed, network lost)
    * `failed` — the browser reported that capture itself failed

  Every status except `failed` can still be listened to, because an ordered
  concatenation of the chunks that did arrive is playable audio. Status is
  honesty about completeness, not about availability.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(recording complete truncated aborted failed)
  @containers ~w(webm mp4 ogg)
  @codecs ~w(opus aac vorbis unknown)
  @channel_layouts ~w(mic_left_sarah_right mono_mix)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "voice_recordings" do
    belongs_to :voice_session, OpenAgents.Voice.Session
    field :generation, :integer
    field :status, :string
    field :container, :string
    field :codec, :string
    field :channel_layout, :string
    field :sealed, :boolean, default: false
    field :chunk_count, :integer, default: 0
    field :byte_size, :integer, default: 0
    field :client_duration_ms, :integer
    field :content_digest, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    has_many :chunks, OpenAgents.Voice.RecordingChunk, foreign_key: :voice_recording_id
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "Statuses whose stored chunks are worth offering to the operator."
  @spec playable_statuses() :: [String.t()]
  def playable_statuses, do: ~w(recording complete truncated aborted)

  def create_changeset(recording, attributes) do
    recording
    |> cast(attributes, [
      :voice_session_id,
      :generation,
      :status,
      :container,
      :codec,
      :channel_layout,
      :sealed,
      :started_at
    ])
    |> validate_required([
      :voice_session_id,
      :generation,
      :status,
      :container,
      :codec,
      :channel_layout,
      :started_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:container, @containers)
    |> validate_inclusion(:codec, @codecs)
    |> validate_inclusion(:channel_layout, @channel_layouts)
    |> validate_number(:generation, greater_than: 0)
    |> foreign_key_constraint(:voice_session_id)
    |> unique_constraint([:voice_session_id, :generation])
    |> check_constraint(:status, name: :voice_recordings_terminal_completion_check)
  end

  def append_changeset(recording, attributes) do
    recording
    |> cast(attributes, [:chunk_count, :byte_size])
    |> validate_required([:chunk_count, :byte_size])
    |> validate_number(:chunk_count, greater_than: recording.chunk_count)
    |> validate_number(:byte_size, greater_than_or_equal_to: recording.byte_size)
  end

  def terminal_changeset(recording, attributes) do
    recording
    |> cast(attributes, [:status, :client_duration_ms, :content_digest, :completed_at])
    |> validate_required([:status, :completed_at])
    |> validate_inclusion(:status, ~w(complete truncated aborted failed))
    |> validate_number(:client_duration_ms, greater_than_or_equal_to: 0)
    |> validate_length(:content_digest, is: 64)
    |> check_constraint(:status, name: :voice_recordings_terminal_completion_check)
  end
end
