defmodule Sarah.Repo.Migrations.CreateVoiceRecordings do
  use Ecto.Migration

  # Call audio becomes durable for the first time here. Two things in this
  # migration are load-bearing beyond the columns:
  #
  #   * `on_delete: :delete_all` down the chain voice_sessions -> conversations
  #     -> visitors -> users is what makes DATA-004 deletion remove audio without
  #     a separate erasure path.
  #   * the byte ceilings are database constraints, not only application checks,
  #     because an upload endpoint that accepts bytes should not depend on a
  #     single code path staying correct.
  def change do
    create table(:voice_recordings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :voice_session_id,
          references(:voice_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :generation, :integer, null: false
      add :status, :string, null: false, default: "recording"
      add :container, :string, null: false
      add :codec, :string, null: false
      add :channel_layout, :string, null: false
      add :sealed, :boolean, null: false, default: false
      add :chunk_count, :integer, null: false, default: 0
      add :byte_size, :bigint, null: false, default: 0
      add :client_duration_ms, :integer
      add :content_digest, :string
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:voice_recordings, [:voice_session_id, :generation])
    create index(:voice_recordings, [:status])
    create index(:voice_recordings, [:started_at])

    create constraint(:voice_recordings, :voice_recordings_status_check,
             check: "status IN ('recording', 'complete', 'truncated', 'aborted', 'failed')"
           )

    create constraint(:voice_recordings, :voice_recordings_container_check,
             check: "container IN ('webm', 'mp4', 'ogg')"
           )

    create constraint(:voice_recordings, :voice_recordings_codec_check,
             check: "codec IN ('opus', 'aac', 'vorbis', 'unknown')"
           )

    create constraint(:voice_recordings, :voice_recordings_channel_layout_check,
             check: "channel_layout IN ('mic_left_sarah_right', 'mono_mix')"
           )

    create constraint(:voice_recordings, :voice_recordings_generation_positive,
             check: "generation > 0"
           )

    create constraint(:voice_recordings, :voice_recordings_counts_nonnegative,
             check: "chunk_count >= 0 AND byte_size >= 0"
           )

    create constraint(:voice_recordings, :voice_recordings_duration_nonnegative,
             check: "client_duration_ms IS NULL OR client_duration_ms >= 0"
           )

    # A terminal recording has a completion time; an open one does not.
    create constraint(:voice_recordings, :voice_recordings_terminal_completion_check,
             check: """
             (status = 'recording' AND completed_at IS NULL)
             OR (status <> 'recording' AND completed_at IS NOT NULL)
             """
           )

    create table(:voice_recording_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :voice_recording_id,
          references(:voice_recordings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :sequence, :integer, null: false
      add :data, :binary, null: false
      add :byte_size, :integer, null: false
      add :observed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:voice_recording_chunks, [:voice_recording_id, :sequence])

    create constraint(:voice_recording_chunks, :voice_recording_chunks_sequence_positive,
             check: "sequence > 0"
           )

    create constraint(:voice_recording_chunks, :voice_recording_chunks_byte_size_positive,
             check: "byte_size > 0"
           )
  end
end
