defmodule Sarah.Repo.Migrations.HardenVoiceReleaseOperations do
  use Ecto.Migration

  @initial_control_id "00000000-0000-0000-0000-000000000001"

  def up do
    create table(:voice_release_controls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :state, :string, null: false
      add :reason, :string, null: false
      add :actor, :string, null: false
      add :source_revision, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:voice_release_controls, :voice_release_controls_state_check,
             check: "state IN ('open', 'draining', 'disabled')"
           )

    create constraint(:voice_release_controls, :voice_release_controls_payload_check,
             check:
               "octet_length(reason) BETWEEN 1 AND 500 AND octet_length(actor) BETWEEN 1 AND 128 AND octet_length(source_revision) BETWEEN 1 AND 128"
           )

    create index(:voice_release_controls, [:inserted_at, :id])

    execute("""
    INSERT INTO voice_release_controls
      (id, state, reason, actor, source_revision, inserted_at)
    VALUES
      ('#{@initial_control_id}', 'open', 'Initial governed voice release state',
       'migration', 'pre-release-control', NOW())
    """)

    execute("""
    CREATE FUNCTION enforce_voice_release_control_append_only() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'voice release controls are append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER voice_release_controls_append_only
    BEFORE UPDATE OR DELETE ON voice_release_controls
    FOR EACH ROW EXECUTE FUNCTION enforce_voice_release_control_append_only();
    """)

    alter table(:voice_sessions) do
      add :release_control_id,
          references(:voice_release_controls, type: :binary_id, on_delete: :restrict),
          null: false,
          default: @initial_control_id

      add :operational_purged_at, :utc_datetime_usec
    end

    execute(
      "ALTER TABLE voice_sessions ALTER COLUMN release_control_id DROP DEFAULT",
      "ALTER TABLE voice_sessions ALTER COLUMN release_control_id SET DEFAULT '#{@initial_control_id}'"
    )

    create table(:voice_client_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :voice_session_id,
          references(:voice_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :generation, :integer, null: false
      add :sequence, :integer, null: false
      add :kind, :string, null: false
      add :browser_family, :string, null: false
      add :browser_major, :integer
      add :observed_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:voice_client_events, [:voice_session_id, :generation, :sequence])
    create index(:voice_client_events, [:kind, :observed_at])

    create constraint(:voice_client_events, :voice_client_events_sequence_check,
             check: "sequence BETWEEN 1 AND 64"
           )

    create constraint(:voice_client_events, :voice_client_events_kind_check,
             check:
               "kind IN ('peer_connected', 'first_remote_track', 'playback_started', 'peer_disconnected', 'interrupt_acknowledged', 'client_failed', 'client_ended')"
           )

    create constraint(:voice_client_events, :voice_client_events_browser_check,
             check:
               "browser_family IN ('chrome', 'safari', 'firefox', 'edge', 'other') AND (browser_major IS NULL OR browser_major BETWEEN 1 AND 1000)"
           )

    execute("""
    CREATE TRIGGER voice_client_event_generation_matches
    BEFORE INSERT OR UPDATE ON voice_client_events
    FOR EACH ROW EXECUTE FUNCTION enforce_voice_child_generation();
    """)

    execute(identity_trigger_up())
  end

  def down do
    execute(identity_trigger_down())
    execute("DROP TRIGGER IF EXISTS voice_client_event_generation_matches ON voice_client_events")
    drop table(:voice_client_events)

    alter table(:voice_sessions) do
      remove :operational_purged_at
      remove :release_control_id
    end

    execute("DROP TRIGGER IF EXISTS voice_release_controls_append_only ON voice_release_controls")
    execute("DROP FUNCTION IF EXISTS enforce_voice_release_control_append_only()")
    drop table(:voice_release_controls)
  end

  defp identity_trigger_up do
    """
    CREATE OR REPLACE FUNCTION enforce_voice_session_identity_immutable() RETURNS trigger AS $$
    DECLARE
      purging boolean;
    BEGIN
      purging := OLD.operational_purged_at IS NULL AND NEW.operational_purged_at IS NOT NULL;

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
         OR NEW.blueprint_revision IS DISTINCT FROM OLD.blueprint_revision
         OR NEW.blueprint_digest IS DISTINCT FROM OLD.blueprint_digest
         OR NEW.program_artifact_id IS DISTINCT FROM OLD.program_artifact_id
         OR NEW.program_artifact_digest IS DISTINCT FROM OLD.program_artifact_digest
         OR NEW.release_control_id IS DISTINCT FROM OLD.release_control_id
         OR NEW.started_at IS DISTINCT FROM OLD.started_at THEN
        RAISE EXCEPTION 'voice session identity is immutable';
      END IF;

      IF purging THEN
        IF OLD.status NOT IN ('ended', 'failed')
           OR NEW.provider_session_id IS NOT NULL
           OR NEW.role_selection IS DISTINCT FROM OLD.role_selection
           OR NEW.instructions IS DISTINCT FROM '[purged after operational retention]'
           OR NEW.tool_catalog IS DISTINCT FROM '{"schema":"sarah.realtime_tool_catalog.v1","tools":[]}'::jsonb
           OR NEW.program_artifact_receipt IS NOT NULL THEN
          RAISE EXCEPTION 'invalid voice operational purge';
        END IF;
      ELSE
        IF NEW.operational_purged_at IS DISTINCT FROM OLD.operational_purged_at
           OR NEW.role_selection IS DISTINCT FROM OLD.role_selection
           OR NEW.instructions IS DISTINCT FROM OLD.instructions
           OR NEW.tool_catalog IS DISTINCT FROM OLD.tool_catalog
           OR NEW.program_artifact_receipt IS DISTINCT FROM OLD.program_artifact_receipt
           OR (OLD.provider_session_id IS NOT NULL AND
               NEW.provider_session_id IS DISTINCT FROM OLD.provider_session_id) THEN
          RAISE EXCEPTION 'voice session identity is immutable';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp identity_trigger_down do
    """
    CREATE OR REPLACE FUNCTION enforce_voice_session_identity_immutable() RETURNS trigger AS $$
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
         OR NEW.role_selection IS DISTINCT FROM OLD.role_selection
         OR NEW.instruction_digest IS DISTINCT FROM OLD.instruction_digest
         OR NEW.instructions IS DISTINCT FROM OLD.instructions
         OR NEW.tool_catalog_digest IS DISTINCT FROM OLD.tool_catalog_digest
         OR NEW.tool_catalog IS DISTINCT FROM OLD.tool_catalog
         OR NEW.blueprint_revision IS DISTINCT FROM OLD.blueprint_revision
         OR NEW.blueprint_digest IS DISTINCT FROM OLD.blueprint_digest
         OR NEW.program_artifact_id IS DISTINCT FROM OLD.program_artifact_id
         OR NEW.program_artifact_digest IS DISTINCT FROM OLD.program_artifact_digest
         OR NEW.program_artifact_receipt IS DISTINCT FROM OLD.program_artifact_receipt
         OR (OLD.provider_session_id IS NOT NULL AND
             NEW.provider_session_id IS DISTINCT FROM OLD.provider_session_id)
         OR NEW.started_at IS DISTINCT FROM OLD.started_at THEN
        RAISE EXCEPTION 'voice session identity is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
