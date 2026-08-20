defmodule OpenAgents.Repo.Migrations.AddRawArgumentsToVoiceToolSteps do
  use Ecto.Migration

  # Owner-directed policy change (issue #72): the durable voice tool step now
  # retains the raw Realtime function arguments as user-owned, deletable
  # conversation evidence alongside the canonical argument digest. The durable
  # voice event ledger stays digest-only; this row is the raw arguments' home.
  # The column is nullable because historical rows predate the policy. The
  # byte ceiling matches the existing `validate_raw_tool_arguments/1` bound in
  # `Sarah.Voice`, and the transition trigger freezes the value with the rest
  # of the request identity.

  def up do
    alter table(:voice_tool_steps) do
      add :raw_arguments, :text
    end

    create constraint(:voice_tool_steps, :voice_tool_steps_raw_arguments_bound_check,
             check: "raw_arguments IS NULL OR octet_length(raw_arguments) <= 16384"
           )

    replace_transition_function(true)
  end

  def down do
    replace_transition_function(false)

    drop constraint(:voice_tool_steps, :voice_tool_steps_raw_arguments_bound_check)

    alter table(:voice_tool_steps) do
      remove :raw_arguments
    end
  end

  defp replace_transition_function(raw_arguments_identity?) do
    old_raw = if raw_arguments_identity?, do: "OLD.raw_arguments,", else: ""
    new_raw = if raw_arguments_identity?, do: "NEW.raw_arguments,", else: ""

    execute("""
    CREATE OR REPLACE FUNCTION enforce_voice_tool_step_transition()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        OLD.voice_session_id, OLD.voice_response_receipt_id, OLD.generation,
        OLD.sequence, OLD.provider_call_id, OLD.provider_item_id,
        OLD.provider_response_id, OLD.tool_name, OLD.tool_version,
        OLD.module_id, OLD.catalog_digest, #{old_raw} OLD.argument_digest,
        OLD.requested_at
      ) IS DISTINCT FROM ROW(
        NEW.voice_session_id, NEW.voice_response_receipt_id, NEW.generation,
        NEW.sequence, NEW.provider_call_id, NEW.provider_item_id,
        NEW.provider_response_id, NEW.tool_name, NEW.tool_version,
        NEW.module_id, NEW.catalog_digest, #{new_raw} NEW.argument_digest,
        NEW.requested_at
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
        NEW.executor_id, NEW.executor_disclosure, NEW.target_receipt_refs,
        NEW.attribution_refs, NEW.started_at, NEW.completed_at
      ) THEN
        RAISE EXCEPTION 'terminal voice tool step is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end
end
