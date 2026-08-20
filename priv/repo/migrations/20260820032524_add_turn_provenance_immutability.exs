defmodule OpenAgents.Repo.Migrations.AddTurnProvenanceImmutability do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION prevent_turn_receipt_identity_update()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        OLD.turn_id,
        OLD.schema_version,
        OLD.model_id,
        OLD.persona_id,
        OLD.persona_digest,
        OLD.role_id,
        OLD.role_digest,
        OLD.instruction_digest,
        OLD.input_digest,
        OLD.input_message_count,
        OLD.input_bytes,
        OLD.tool_catalog_digest,
        OLD.blueprint_revision,
        OLD.blueprint_digest,
        OLD.program_artifact_id,
        OLD.program_artifact_digest,
        OLD.memory_snapshot_ref,
        OLD.provider_started_at
      ) IS DISTINCT FROM ROW(
        NEW.turn_id,
        NEW.schema_version,
        NEW.model_id,
        NEW.persona_id,
        NEW.persona_digest,
        NEW.role_id,
        NEW.role_digest,
        NEW.instruction_digest,
        NEW.input_digest,
        NEW.input_message_count,
        NEW.input_bytes,
        NEW.tool_catalog_digest,
        NEW.blueprint_revision,
        NEW.blueprint_digest,
        NEW.program_artifact_id,
        NEW.program_artifact_digest,
        NEW.memory_snapshot_ref,
        NEW.provider_started_at
      ) THEN
        RAISE EXCEPTION 'turn receipt identity is immutable';
      END IF;

      IF OLD.status <> 'captured' AND ROW(
        OLD.status,
        OLD.used_source_refs,
        OLD.used_tool_step_refs,
        OLD.used_preferences,
        OLD.used_experiences,
        OLD.used_memory_evidence,
        OLD.usage,
        OLD.provider_completed_at
      ) IS DISTINCT FROM ROW(
        NEW.status,
        NEW.used_source_refs,
        NEW.used_tool_step_refs,
        NEW.used_preferences,
        NEW.used_experiences,
        NEW.used_memory_evidence,
        NEW.usage,
        NEW.provider_completed_at
      ) THEN
        RAISE EXCEPTION 'terminal turn receipt is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("DROP TRIGGER IF EXISTS turn_receipts_prevent_identity_update ON turn_receipts")

    execute("""
    CREATE TRIGGER turn_receipts_prevent_identity_update
    BEFORE UPDATE ON turn_receipts
    FOR EACH ROW
    EXECUTE FUNCTION prevent_turn_receipt_identity_update()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION protect_turn_role_selection()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.role_selection IS DISTINCT FROM NEW.role_selection THEN
        RAISE EXCEPTION 'turn role selection is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("DROP TRIGGER IF EXISTS protect_turn_role_selection_trigger ON turn_receipts")

    execute("""
    CREATE TRIGGER protect_turn_role_selection_trigger
    BEFORE UPDATE ON turn_receipts
    FOR EACH ROW EXECUTE FUNCTION protect_turn_role_selection()
    """)

    execute("DROP TRIGGER IF EXISTS protect_voice_role_selection_trigger ON voice_sessions")

    execute("""
    CREATE TRIGGER protect_voice_role_selection_trigger
    BEFORE UPDATE ON voice_sessions
    FOR EACH ROW EXECUTE FUNCTION protect_turn_role_selection()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION prevent_turn_receipt_profile_memory_snapshot_update()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.profile_memory_snapshot_ref IS DISTINCT FROM NEW.profile_memory_snapshot_ref THEN
        RAISE EXCEPTION 'turn receipt profile memory snapshot is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "DROP TRIGGER IF EXISTS turn_receipts_prevent_profile_memory_snapshot_update ON turn_receipts"
    )

    execute("""
    CREATE TRIGGER turn_receipts_prevent_profile_memory_snapshot_update
    BEFORE UPDATE ON turn_receipts
    FOR EACH ROW EXECUTE FUNCTION prevent_turn_receipt_profile_memory_snapshot_update()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION protect_turn_program_capture()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.program_artifact_receipt IS DISTINCT FROM NEW.program_artifact_receipt THEN
        RAISE EXCEPTION 'turn program capture is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("DROP TRIGGER IF EXISTS protect_turn_program_capture_trigger ON turn_receipts")

    execute("""
    CREATE TRIGGER protect_turn_program_capture_trigger
    BEFORE UPDATE ON turn_receipts
    FOR EACH ROW EXECUTE FUNCTION protect_turn_program_capture()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION prevent_terminal_memory_evidence_update()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.status <> 'captured' AND
         OLD.used_memory_evidence IS DISTINCT FROM NEW.used_memory_evidence THEN
        RAISE EXCEPTION 'terminal memory evidence is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "DROP TRIGGER IF EXISTS turn_receipts_prevent_terminal_memory_evidence_update ON turn_receipts"
    )

    execute("""
    CREATE TRIGGER turn_receipts_prevent_terminal_memory_evidence_update
    BEFORE UPDATE ON turn_receipts
    FOR EACH ROW
    EXECUTE FUNCTION prevent_terminal_memory_evidence_update()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION prevent_provider_step_rewrite()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        OLD.turn_receipt_id,
        OLD.sequence,
        OLD.provider_id,
        OLD.model_id,
        OLD.started_at
      ) IS DISTINCT FROM ROW(
        NEW.turn_receipt_id,
        NEW.sequence,
        NEW.provider_id,
        NEW.model_id,
        NEW.started_at
      ) THEN
        RAISE EXCEPTION 'provider step identity is immutable';
      END IF;

      IF OLD.status <> 'started' AND ROW(
        OLD.status,
        OLD.provider_response_id,
        OLD.usage,
        OLD.error_code,
        OLD.completed_at
      ) IS DISTINCT FROM ROW(
        NEW.status,
        NEW.provider_response_id,
        NEW.usage,
        NEW.error_code,
        NEW.completed_at
      ) THEN
        RAISE EXCEPTION 'terminal provider step is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("DROP TRIGGER IF EXISTS turn_provider_steps_prevent_rewrite ON turn_provider_steps")

    execute("""
    CREATE TRIGGER turn_provider_steps_prevent_rewrite
    BEFORE UPDATE ON turn_provider_steps
    FOR EACH ROW
    EXECUTE FUNCTION prevent_provider_step_rewrite()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION enforce_turn_tool_step_transition()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        OLD.turn_id, OLD.turn_receipt_id, OLD.sequence, OLD.provider_call_id,
        OLD.provider_item_id, OLD.provider_response_id, OLD.tool_name,
        OLD.tool_version, OLD.module_id, OLD.module_artifact_digest,
        OLD.executor_implementation_digest, OLD.routing_receipt_id,
        OLD.side_effect_class, OLD.invocation_key, OLD.attribution_policy_id,
        OLD.attribution_policy_version, OLD.attribution_policy_digest,
        OLD.billable, OLD.billable_attribution_key, OLD.cost_units,
        OLD.catalog_digest, OLD.raw_arguments, OLD.argument_digest, OLD.requested_at
      ) IS DISTINCT FROM ROW(
        NEW.turn_id, NEW.turn_receipt_id, NEW.sequence, NEW.provider_call_id,
        NEW.provider_item_id, NEW.provider_response_id, NEW.tool_name,
        NEW.tool_version, NEW.module_id, NEW.module_artifact_digest,
        NEW.executor_implementation_digest, NEW.routing_receipt_id,
        NEW.side_effect_class, NEW.invocation_key, NEW.attribution_policy_id,
        NEW.attribution_policy_version, NEW.attribution_policy_digest,
        NEW.billable, NEW.billable_attribution_key, NEW.cost_units,
        NEW.catalog_digest, NEW.raw_arguments, NEW.argument_digest, NEW.requested_at
      ) THEN
        RAISE EXCEPTION 'tool step identity is immutable';
      END IF;

      IF OLD.status = 'requested' AND NEW.status NOT IN (
        'requested', 'running', 'succeeded', 'failed', 'refused',
        'cancelled', 'unavailable', 'interrupted'
      ) THEN
        RAISE EXCEPTION 'invalid requested tool step transition';
      END IF;

      IF OLD.status = 'running' AND NEW.status NOT IN (
        'running', 'succeeded', 'failed', 'refused', 'cancelled',
        'unavailable', 'interrupted'
      ) THEN
        RAISE EXCEPTION 'invalid running tool step transition';
      END IF;

      IF OLD.status NOT IN ('requested', 'running') AND ROW(
        OLD.status, OLD.outcome_digest, OLD.outcome_receipt_ref, OLD.usage,
        OLD.result, OLD.error,
        OLD.executor_id, OLD.executor_disclosure, OLD.target_receipt_refs,
        OLD.attribution_refs, OLD.started_at, OLD.completed_at
      ) IS DISTINCT FROM ROW(
        NEW.status, NEW.outcome_digest, NEW.outcome_receipt_ref, NEW.usage,
        NEW.result, NEW.error,
        NEW.executor_id, NEW.executor_disclosure, NEW.target_receipt_refs,
        NEW.attribution_refs, NEW.started_at, NEW.completed_at
      ) THEN
        RAISE EXCEPTION 'terminal tool step is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("DROP TRIGGER IF EXISTS turn_tool_steps_enforce_transition ON turn_tool_steps")

    execute("""
    CREATE TRIGGER turn_tool_steps_enforce_transition
    BEFORE UPDATE ON turn_tool_steps
    FOR EACH ROW
    EXECUTE FUNCTION enforce_turn_tool_step_transition()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS turn_tool_steps_enforce_transition ON turn_tool_steps")
    execute("DROP FUNCTION IF EXISTS enforce_turn_tool_step_transition()")

    execute("DROP TRIGGER IF EXISTS turn_provider_steps_prevent_rewrite ON turn_provider_steps")
    execute("DROP FUNCTION IF EXISTS prevent_provider_step_rewrite()")

    execute(
      "DROP TRIGGER IF EXISTS turn_receipts_prevent_terminal_memory_evidence_update ON turn_receipts"
    )

    execute("DROP FUNCTION IF EXISTS prevent_terminal_memory_evidence_update()")

    execute("DROP TRIGGER IF EXISTS protect_turn_program_capture_trigger ON turn_receipts")
    execute("DROP FUNCTION IF EXISTS protect_turn_program_capture()")

    execute(
      "DROP TRIGGER IF EXISTS turn_receipts_prevent_profile_memory_snapshot_update ON turn_receipts"
    )

    execute("DROP FUNCTION IF EXISTS prevent_turn_receipt_profile_memory_snapshot_update()")

    execute("DROP TRIGGER IF EXISTS protect_voice_role_selection_trigger ON voice_sessions")
    execute("DROP TRIGGER IF EXISTS protect_turn_role_selection_trigger ON turn_receipts")
    execute("DROP FUNCTION IF EXISTS protect_turn_role_selection()")

    execute("DROP TRIGGER IF EXISTS turn_receipts_prevent_identity_update ON turn_receipts")
    execute("DROP FUNCTION IF EXISTS prevent_turn_receipt_identity_update()")
  end
end
