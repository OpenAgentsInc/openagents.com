defmodule Sarah.Repo.Migrations.CreateVoiceRuntime do
  use Ecto.Migration

  def up do
    create table(:voice_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :generation, :integer, null: false
      add :status, :string, null: false
      add :architecture, :string, null: false
      add :provider_id, :string, null: false
      add :model_id, :string, null: false
      add :voice_artifact_id, :string, null: false
      add :provider_session_id, :string
      add :persona_id, :string, null: false
      add :persona_digest, :string, null: false
      add :role_id, :string, null: false
      add :role_digest, :string, null: false
      add :instruction_digest, :string, null: false
      add :tool_catalog_digest, :string, null: false
      add :event_sequence, :integer, null: false, default: 0
      add :usage, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec, null: false
      add :connected_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :termination_reason, :string
      add :failure_code, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:voice_sessions, [:conversation_id, :generation])

    create unique_index(:voice_sessions, [:conversation_id],
             where:
               "status IN ('connecting', 'listening', 'responding', 'interrupted', 'reconnecting')",
             name: :voice_sessions_one_active_per_conversation_index
           )

    create unique_index(:voice_sessions, [:provider_session_id],
             where: "provider_session_id IS NOT NULL"
           )

    create constraint(:voice_sessions, :voice_sessions_generation_positive,
             check: "generation > 0"
           )

    create constraint(:voice_sessions, :voice_sessions_event_sequence_nonnegative,
             check: "event_sequence >= 0"
           )

    create constraint(:voice_sessions, :voice_sessions_status_allowed,
             check:
               "status IN ('connecting', 'listening', 'responding', 'interrupted', 'reconnecting', 'ended', 'failed')"
           )

    create constraint(:voice_sessions, :voice_sessions_terminal_shape,
             check:
               "(status NOT IN ('ended', 'failed')) OR (ended_at IS NOT NULL AND termination_reason IS NOT NULL)"
           )

    create table(:voice_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :voice_session_id,
          references(:voice_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :generation, :integer, null: false
      add :sequence, :integer, null: false
      add :provider_event_id, :string
      add :kind, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :observed_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:voice_events, [:voice_session_id, :sequence])

    create unique_index(:voice_events, [:voice_session_id, :generation, :provider_event_id],
             where: "provider_event_id IS NOT NULL",
             name: :voice_events_provider_event_id_index
           )

    create constraint(:voice_events, :voice_events_sequence_positive, check: "sequence > 0")

    create constraint(:voice_events, :voice_events_payload_bounded,
             check: "octet_length(payload::text) <= 16384"
           )

    create table(:voice_response_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :voice_session_id,
          references(:voice_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :generation, :integer, null: false
      add :provider_response_id, :string, null: false
      add :status, :string, null: false
      add :started_event_sequence, :integer, null: false
      add :terminal_event_sequence, :integer
      add :usage, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :voice_response_receipts,
             [
               :voice_session_id,
               :generation,
               :provider_response_id
             ],
             name: :voice_response_provider_id_index
           )

    create constraint(:voice_response_receipts, :voice_response_receipts_status_allowed,
             check: "status IN ('responding', 'completed', 'interrupted', 'failed')"
           )

    create constraint(:voice_response_receipts, :voice_response_receipts_sequence_shape,
             check:
               "started_event_sequence > 0 AND (terminal_event_sequence IS NULL OR terminal_event_sequence >= started_event_sequence)"
           )

    create constraint(:voice_response_receipts, :voice_response_receipts_terminal_shape,
             check:
               "(status = 'responding' AND terminal_event_sequence IS NULL) OR (status != 'responding' AND terminal_event_sequence IS NOT NULL)"
           )

    create table(:voice_transcript_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :voice_session_id,
          references(:voice_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :generation, :integer, null: false
      add :provider_item_id, :string, null: false
      add :provider_response_id, :string
      add :role, :string, null: false
      add :content, :text, null: false
      add :status, :string, null: false
      add :observed_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :voice_transcript_items,
             [
               :voice_session_id,
               :generation,
               :provider_item_id,
               :role
             ],
             name: :voice_transcript_provider_item_role_index
           )

    create constraint(:voice_transcript_items, :voice_transcript_items_role_allowed,
             check: "role IN ('user', 'assistant')"
           )

    create constraint(:voice_transcript_items, :voice_transcript_items_status_allowed,
             check: "status IN ('final', 'interrupted')"
           )

    create constraint(:voice_transcript_items, :voice_transcript_items_content_bounded,
             check: "octet_length(content) BETWEEN 1 AND 16000"
           )

    execute("""
    CREATE FUNCTION enforce_voice_session_identity_immutable() RETURNS trigger AS $$
    BEGIN
      IF NEW.conversation_id IS DISTINCT FROM OLD.conversation_id
         OR NEW.generation IS DISTINCT FROM OLD.generation
         OR NEW.architecture IS DISTINCT FROM OLD.architecture
         OR NEW.provider_id IS DISTINCT FROM OLD.provider_id
         OR NEW.model_id IS DISTINCT FROM OLD.model_id
         OR NEW.voice_artifact_id IS DISTINCT FROM OLD.voice_artifact_id
         OR NEW.persona_id IS DISTINCT FROM OLD.persona_id
         OR NEW.persona_digest IS DISTINCT FROM OLD.persona_digest
         OR NEW.role_id IS DISTINCT FROM OLD.role_id
         OR NEW.role_digest IS DISTINCT FROM OLD.role_digest
         OR NEW.instruction_digest IS DISTINCT FROM OLD.instruction_digest
         OR NEW.tool_catalog_digest IS DISTINCT FROM OLD.tool_catalog_digest
         OR (OLD.provider_session_id IS NOT NULL AND
             NEW.provider_session_id IS DISTINCT FROM OLD.provider_session_id)
         OR NEW.started_at IS DISTINCT FROM OLD.started_at THEN
        RAISE EXCEPTION 'voice session identity is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER voice_session_identity_immutable
    BEFORE UPDATE ON voice_sessions
    FOR EACH ROW EXECUTE FUNCTION enforce_voice_session_identity_immutable();
    """)

    execute("""
    CREATE FUNCTION enforce_voice_child_generation() RETURNS trigger AS $$
    DECLARE
      admitted_generation integer;
    BEGIN
      SELECT generation INTO admitted_generation
      FROM voice_sessions
      WHERE id = NEW.voice_session_id;

      IF admitted_generation IS NULL OR NEW.generation IS DISTINCT FROM admitted_generation THEN
        RAISE EXCEPTION 'voice child generation does not match admitted session';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER voice_event_generation_matches
    BEFORE INSERT OR UPDATE ON voice_events
    FOR EACH ROW EXECUTE FUNCTION enforce_voice_child_generation();
    """)

    execute("""
    CREATE TRIGGER voice_transcript_generation_matches
    BEFORE INSERT OR UPDATE ON voice_transcript_items
    FOR EACH ROW EXECUTE FUNCTION enforce_voice_child_generation();
    """)

    execute("""
    CREATE TRIGGER voice_response_receipt_generation_matches
    BEFORE INSERT OR UPDATE ON voice_response_receipts
    FOR EACH ROW EXECUTE FUNCTION enforce_voice_child_generation();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS voice_response_receipt_generation_matches ON voice_response_receipts"
    )

    execute(
      "DROP TRIGGER IF EXISTS voice_transcript_generation_matches ON voice_transcript_items"
    )

    execute("DROP TRIGGER IF EXISTS voice_event_generation_matches ON voice_events")
    execute("DROP FUNCTION IF EXISTS enforce_voice_child_generation()")
    execute("DROP TRIGGER IF EXISTS voice_session_identity_immutable ON voice_sessions")
    execute("DROP FUNCTION IF EXISTS enforce_voice_session_identity_immutable()")
    drop table(:voice_transcript_items)
    drop table(:voice_response_receipts)
    drop table(:voice_events)
    drop table(:voice_sessions)
  end
end
