defmodule OpenAgents.Repo.Migrations.GovernVoiceContextToolsAndChronology do
  use Ecto.Migration

  def up do
    create constraint(:messages, :messages_modality_check, check: "modality IN ('text', 'voice')")

    create constraint(:messages, :messages_voice_provenance_check,
             check:
               "(modality = 'text' AND voice_session_id IS NULL AND provider_item_id IS NULL AND transcript_kind IS NULL AND interrupted = false) OR " <>
                 "(modality = 'voice' AND voice_session_id IS NOT NULL AND provider_item_id IS NOT NULL AND transcript_kind IN ('provider_input_transcription', 'provider_output_transcript'))"
           )

    execute("""
    CREATE FUNCTION enforce_voice_message_transition() RETURNS trigger AS $$
    BEGIN
      IF OLD.modality = 'voice' THEN
        IF ROW(
          OLD.conversation_id, OLD.role, OLD.content, OLD.modality,
          OLD.voice_session_id, OLD.provider_item_id, OLD.transcript_kind
        ) IS DISTINCT FROM ROW(
          NEW.conversation_id, NEW.role, NEW.content, NEW.modality,
          NEW.voice_session_id, NEW.provider_item_id, NEW.transcript_kind
        ) THEN
          RAISE EXCEPTION 'voice message evidence is immutable';
        END IF;

        IF OLD.status IN ('complete', 'failed', 'cancelled') AND
           ROW(OLD.status, OLD.interrupted) IS DISTINCT FROM
           ROW(NEW.status, NEW.interrupted) THEN
          RAISE EXCEPTION 'terminal voice message is immutable';
        END IF;

        IF OLD.interrupted = true AND NEW.interrupted = false THEN
          RAISE EXCEPTION 'voice interruption is irreversible';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER messages_enforce_voice_transition
    BEFORE UPDATE ON messages
    FOR EACH ROW EXECUTE FUNCTION enforce_voice_message_transition();
    """)

    alter table(:voice_sessions) do
      add :instructions, :text, null: false, default: ""

      add :tool_catalog, :map,
        null: false,
        default: %{"schema" => "sarah.realtime_tool_catalog.v1", "tools" => []}

      add :blueprint_revision, :string
      add :blueprint_digest, :string
      add :program_artifact_id, :string
      add :program_artifact_digest, :string
      add :program_artifact_receipt, :map
    end

    create constraint(:voice_sessions, :voice_sessions_context_digest_check,
             check:
               "(blueprint_digest IS NULL OR blueprint_digest ~ '^[0-9a-f]{64}$') AND " <>
                 "(program_artifact_digest IS NULL OR program_artifact_digest ~ '^[0-9a-f]{64}$') AND " <>
                 "octet_length(instructions) <= 65536 AND octet_length(tool_catalog::text) <= 65536"
           )

    create constraint(:voice_sessions, :voice_sessions_tool_catalog_check,
             check:
               "jsonb_typeof(tool_catalog) = 'object' AND " <>
                 "tool_catalog->>'schema' = 'sarah.realtime_tool_catalog.v1' AND " <>
                 "jsonb_typeof(tool_catalog->'tools') = 'array'"
           )

    create constraint(:voice_sessions, :voice_sessions_program_capture_check,
             check:
               "program_artifact_receipt IS NULL OR (" <>
                 "jsonb_typeof(program_artifact_receipt) = 'object' AND " <>
                 "program_artifact_receipt->>'schema' = 'sarah.program_capture.v1' AND " <>
                 "program_artifact_receipt->>'artifact_id' IS NOT DISTINCT FROM program_artifact_id AND " <>
                 "program_artifact_receipt->>'artifact_digest' IS NOT DISTINCT FROM program_artifact_digest AND " <>
                 "jsonb_typeof(program_artifact_receipt->'degraded') = 'boolean' AND " <>
                 "octet_length(program_artifact_receipt::text) <= 4096)"
           )

    create table(:voice_response_contexts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :voice_session_id,
          references(:voice_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :generation, :integer, null: false

      add :user_message_id,
          references(:messages, type: :binary_id, on_delete: :restrict),
          null: false

      add :provider_input_item_id, :string, null: false
      add :instructions, :text, null: false
      add :instruction_digest, :string, null: false
      add :memory_snapshot_ref, :string, null: false
      add :profile_memory_snapshot_ref, :string, null: false
      add :selected_evidence, :map, null: false
      add :selected_source_refs, {:array, :string}, null: false, default: []
      add :program_artifact_id, :string
      add :program_artifact_digest, :string
      add :program_artifact_receipt, :map, null: false
      add :captured_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :voice_response_contexts,
             [:voice_session_id, :generation, :provider_input_item_id],
             name: :voice_response_context_input_item_index
           )

    create unique_index(:voice_response_contexts, [:user_message_id])

    create constraint(:voice_response_contexts, :voice_response_contexts_digest_check,
             check:
               "instruction_digest ~ '^[0-9a-f]{64}$' AND " <>
                 "(program_artifact_digest IS NULL OR program_artifact_digest ~ '^[0-9a-f]{64}$')"
           )

    create constraint(:voice_response_contexts, :voice_response_contexts_snapshot_check,
             check:
               "memory_snapshot_ref ~ '^message:[0-9a-f-]{36}$' AND " <>
                 "profile_memory_snapshot_ref ~ '^profile-memory-snapshot:v1:[0-9a-f-]{36}$'"
           )

    create constraint(:voice_response_contexts, :voice_response_contexts_payload_check,
             check:
               "octet_length(instructions) BETWEEN 1 AND 65536 AND " <>
                 "octet_length(selected_evidence::text) <= 65536 AND " <>
                 "octet_length(program_artifact_receipt::text) <= 4096"
           )

    alter table(:voice_response_receipts) do
      add :response_context_id,
          references(:voice_response_contexts, type: :binary_id, on_delete: :restrict)

      add :assistant_message_id, references(:messages, type: :binary_id, on_delete: :restrict)
      add :used_source_refs, {:array, :string}, null: false, default: []
      add :used_tool_step_refs, {:array, :string}, null: false, default: []

      add :used_memory_evidence, :map,
        null: false,
        default: %{"schema" => "sarah.memory_evidence_usage.v1", "items" => []}
    end

    alter table(:voice_transcript_items) do
      add :message_id, references(:messages, type: :binary_id, on_delete: :restrict)
    end

    create unique_index(:voice_transcript_items, [:message_id], where: "message_id IS NOT NULL")

    create table(:voice_tool_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :voice_session_id,
          references(:voice_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :voice_response_receipt_id,
          references(:voice_response_receipts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :generation, :integer, null: false
      add :sequence, :integer, null: false
      add :provider_call_id, :string, null: false
      add :provider_item_id, :string, null: false
      add :provider_response_id, :string, null: false
      add :tool_name, :string, null: false
      add :tool_version, :integer, null: false
      add :module_id, :string, null: false
      add :catalog_digest, :string, null: false
      add :argument_digest, :string, null: false
      add :status, :string, null: false, default: "requested"
      add :outcome_digest, :string
      add :result, :map
      add :error, :map
      add :executor_id, :string
      add :executor_disclosure, :string
      add :target_receipt_refs, {:array, :string}, null: false, default: []
      add :attribution_refs, {:array, :string}, null: false, default: []
      add :requested_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:voice_tool_steps, [:voice_session_id, :generation, :sequence],
             name: :voice_tool_steps_sequence_index
           )

    create unique_index(:voice_tool_steps, [:voice_session_id, :generation, :provider_call_id],
             name: :voice_tool_steps_provider_call_index
           )

    create constraint(:voice_tool_steps, :voice_tool_steps_sequence_check,
             check: "sequence > 0 AND sequence <= 32"
           )

    create constraint(:voice_tool_steps, :voice_tool_steps_status_check,
             check:
               "status IN ('requested', 'running', 'succeeded', 'failed', 'refused', 'cancelled', 'unavailable', 'interrupted')"
           )

    create constraint(:voice_tool_steps, :voice_tool_steps_digest_check,
             check:
               "catalog_digest ~ '^[0-9a-f]{64}$' AND argument_digest ~ '^[0-9a-f]{64}$' AND (outcome_digest IS NULL OR outcome_digest ~ '^[0-9a-f]{64}$')"
           )

    create constraint(:voice_tool_steps, :voice_tool_steps_lifecycle_shape_check,
             check:
               "(status = 'requested' AND started_at IS NULL AND completed_at IS NULL AND outcome_digest IS NULL AND result IS NULL AND error IS NULL) OR " <>
                 "(status = 'running' AND started_at IS NOT NULL AND completed_at IS NULL AND outcome_digest IS NULL AND result IS NULL AND error IS NULL) OR " <>
                 "(status = 'succeeded' AND completed_at IS NOT NULL AND outcome_digest IS NOT NULL AND result IS NOT NULL AND error IS NULL AND executor_id IS NOT NULL AND executor_disclosure IS NOT NULL) OR " <>
                 "(status IN ('failed', 'refused', 'cancelled', 'unavailable', 'interrupted') AND completed_at IS NOT NULL AND outcome_digest IS NOT NULL AND result IS NULL AND error IS NOT NULL AND executor_id IS NOT NULL AND executor_disclosure IS NOT NULL)"
           )

    execute("""
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
    """)

    execute("""
    CREATE TRIGGER voice_response_context_generation_matches
    BEFORE INSERT OR UPDATE ON voice_response_contexts
    FOR EACH ROW EXECUTE FUNCTION enforce_voice_child_generation();
    """)

    execute("""
    CREATE TRIGGER voice_tool_step_generation_matches
    BEFORE INSERT OR UPDATE ON voice_tool_steps
    FOR EACH ROW EXECUTE FUNCTION enforce_voice_child_generation();
    """)

    execute("""
    CREATE FUNCTION enforce_voice_tool_step_transition()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        OLD.voice_session_id, OLD.voice_response_receipt_id, OLD.generation,
        OLD.sequence, OLD.provider_call_id, OLD.provider_item_id,
        OLD.provider_response_id, OLD.tool_name, OLD.tool_version,
        OLD.module_id, OLD.catalog_digest, OLD.argument_digest, OLD.requested_at
      ) IS DISTINCT FROM ROW(
        NEW.voice_session_id, NEW.voice_response_receipt_id, NEW.generation,
        NEW.sequence, NEW.provider_call_id, NEW.provider_item_id,
        NEW.provider_response_id, NEW.tool_name, NEW.tool_version,
        NEW.module_id, NEW.catalog_digest, NEW.argument_digest, NEW.requested_at
      ) THEN
        RAISE EXCEPTION 'voice tool step identity is immutable';
      END IF;

      IF OLD.status = 'requested' AND NEW.status NOT IN (
        'requested', 'running', 'succeeded', 'failed', 'refused',
        'cancelled', 'unavailable', 'interrupted'
      ) THEN
        RAISE EXCEPTION 'invalid requested voice tool step transition';
      END IF;

      IF OLD.status = 'running' AND NEW.status NOT IN (
        'running', 'succeeded', 'failed', 'refused', 'cancelled',
        'unavailable', 'interrupted'
      ) THEN
        RAISE EXCEPTION 'invalid running voice tool step transition';
      END IF;

      IF OLD.status NOT IN ('requested', 'running') AND ROW(
        OLD.status, OLD.outcome_digest, OLD.result, OLD.error,
        OLD.executor_id, OLD.executor_disclosure, OLD.target_receipt_refs,
        OLD.attribution_refs, OLD.started_at, OLD.completed_at
      ) IS DISTINCT FROM ROW(
        NEW.status, NEW.outcome_digest, NEW.result, NEW.error,
        NEW.executor_id, NEW.executor_disclosure, OLD.target_receipt_refs,
        NEW.attribution_refs, NEW.started_at, NEW.completed_at
      ) THEN
        RAISE EXCEPTION 'terminal voice tool step is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER voice_tool_steps_enforce_transition
    BEFORE UPDATE ON voice_tool_steps
    FOR EACH ROW EXECUTE FUNCTION enforce_voice_tool_step_transition();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS voice_tool_steps_enforce_transition ON voice_tool_steps")
    execute("DROP FUNCTION IF EXISTS enforce_voice_tool_step_transition()")
    execute("DROP TRIGGER IF EXISTS voice_tool_step_generation_matches ON voice_tool_steps")

    execute(
      "DROP TRIGGER IF EXISTS voice_response_context_generation_matches ON voice_response_contexts"
    )

    execute("DROP TRIGGER IF EXISTS messages_enforce_voice_transition ON messages")
    execute("DROP FUNCTION IF EXISTS enforce_voice_message_transition()")

    drop table(:voice_tool_steps)

    alter table(:voice_transcript_items) do
      remove :message_id
    end

    alter table(:voice_response_receipts) do
      remove :used_memory_evidence
      remove :used_tool_step_refs
      remove :used_source_refs
      remove :assistant_message_id
      remove :response_context_id
    end

    drop table(:voice_response_contexts)

    alter table(:voice_sessions) do
      remove :program_artifact_receipt
      remove :program_artifact_digest
      remove :program_artifact_id
      remove :blueprint_digest
      remove :blueprint_revision
      remove :tool_catalog
      remove :instructions
    end

    execute("""
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
    """)

    drop constraint(:messages, :messages_voice_provenance_check)
    drop constraint(:messages, :messages_modality_check)
  end
end
