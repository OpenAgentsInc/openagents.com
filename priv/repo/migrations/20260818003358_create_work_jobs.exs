defmodule Sarah.Repo.Migrations.CreateWorkJobs do
  use Ecto.Migration

  def up do
    create table(:work_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :owner_visitor_id,
          references(:visitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :surface, :string, null: false
      add :goal, :text, null: false
      add :context_hint, :text
      add :requesting_tool_step_ref, :string
      add :status, :string, null: false, default: "queued"
      add :report, :text
      add :error_code, :string
      add :model_id, :string
      add :instruction_digest, :string
      add :tool_catalog_digest, :string
      add :memory_snapshot_ref, :string
      add :tool_call_count, :integer, null: false, default: 0
      add :continuation_count, :integer, null: false, default: 0
      add :usage, :map

      add :report_message_id,
          references(:messages, type: :binary_id, on_delete: :nilify_all)

      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:work_jobs, [:conversation_id, :inserted_at])
    create index(:work_jobs, [:status])

    create constraint(:work_jobs, :work_jobs_surface_check, check: "surface IN ('text', 'voice')")

    create constraint(:work_jobs, :work_jobs_goal_check, check: "goal <> ''")

    create constraint(:work_jobs, :work_jobs_status_check,
             check:
               "status IN ('queued', 'running', 'completed', 'failed', 'interrupted', 'budget_exhausted')"
           )

    # Every terminal path must carry a non-empty report: partial findings on a
    # limit or interruption, never silent death. See INVARIANTS.md WORK-001.
    create constraint(:work_jobs, :work_jobs_terminal_report_check,
             check:
               "(status IN ('queued', 'running') AND completed_at IS NULL) OR (status IN ('completed', 'failed', 'interrupted', 'budget_exhausted') AND completed_at IS NOT NULL AND report IS NOT NULL AND report <> '')"
           )

    execute("""
    CREATE FUNCTION enforce_work_job_transition()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        OLD.conversation_id, OLD.owner_visitor_id, OLD.surface, OLD.goal,
        OLD.context_hint, OLD.requesting_tool_step_ref
      ) IS DISTINCT FROM ROW(
        NEW.conversation_id, NEW.owner_visitor_id, NEW.surface, NEW.goal,
        NEW.context_hint, NEW.requesting_tool_step_ref
      ) THEN
        RAISE EXCEPTION 'work job identity is immutable';
      END IF;

      IF OLD.status = 'queued' AND NEW.status NOT IN (
        'queued', 'running', 'failed', 'interrupted'
      ) THEN
        RAISE EXCEPTION 'invalid queued work job transition';
      END IF;

      IF OLD.status = 'running' AND NEW.status NOT IN (
        'running', 'completed', 'failed', 'interrupted', 'budget_exhausted'
      ) THEN
        RAISE EXCEPTION 'invalid running work job transition';
      END IF;

      -- report_message_id is a projection link, not identity: the DATA-004
      -- account-deletion cascade sets it NULL while removing the messages, so
      -- it stays out of the terminal-immutable row.
      IF OLD.status NOT IN ('queued', 'running') AND ROW(
        OLD.status, OLD.report, OLD.error_code, OLD.usage, OLD.completed_at
      ) IS DISTINCT FROM ROW(
        NEW.status, NEW.report, NEW.error_code, NEW.usage, NEW.completed_at
      ) THEN
        RAISE EXCEPTION 'terminal work job is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER work_jobs_enforce_transition
    BEFORE UPDATE ON work_jobs
    FOR EACH ROW
    EXECUTE FUNCTION enforce_work_job_transition();
    """)

    create table(:work_job_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :work_job_id,
          references(:work_jobs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :sequence, :integer, null: false
      add :provider_call_id, :string, null: false
      add :provider_item_id, :string, null: false
      add :provider_response_id, :string, null: false
      add :tool_name, :string, null: false
      add :tool_version, :integer, null: false
      add :module_id, :string, null: false
      add :module_artifact_digest, :string
      add :catalog_digest, :string, null: false
      add :argument_digest, :string, null: false
      add :status, :string, null: false, default: "requested"
      add :outcome_digest, :string
      add :result, :map
      add :error, :map
      add :usage, :map
      add :executor_id, :string
      add :executor_disclosure, :string
      add :target_receipt_refs, {:array, :string}, null: false, default: []
      add :attribution_refs, {:array, :string}, null: false, default: []
      add :requested_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:work_job_steps, [:work_job_id, :sequence])
    create unique_index(:work_job_steps, [:work_job_id, :provider_call_id])

    create constraint(:work_job_steps, :work_job_steps_sequence_check,
             check: "sequence > 0 AND sequence <= 64"
           )

    create constraint(:work_job_steps, :work_job_steps_status_check,
             check:
               "status IN ('requested', 'running', 'succeeded', 'failed', 'refused', 'cancelled', 'unavailable', 'interrupted')"
           )

    create constraint(:work_job_steps, :work_job_steps_digest_check,
             check:
               "catalog_digest ~ '^[0-9a-f]{64}$' AND argument_digest ~ '^[0-9a-f]{64}$' AND (outcome_digest IS NULL OR outcome_digest ~ '^[0-9a-f]{64}$')"
           )

    create constraint(:work_job_steps, :work_job_steps_lifecycle_shape_check,
             check:
               "(status = 'requested' AND started_at IS NULL AND completed_at IS NULL AND outcome_digest IS NULL AND result IS NULL AND error IS NULL) OR (status = 'running' AND started_at IS NOT NULL AND completed_at IS NULL AND outcome_digest IS NULL AND result IS NULL AND error IS NULL) OR (status = 'succeeded' AND completed_at IS NOT NULL AND outcome_digest IS NOT NULL AND result IS NOT NULL AND error IS NULL AND executor_id IS NOT NULL AND executor_disclosure IS NOT NULL) OR (status IN ('failed', 'refused', 'cancelled', 'unavailable', 'interrupted') AND completed_at IS NOT NULL AND outcome_digest IS NOT NULL AND result IS NULL AND error IS NOT NULL AND executor_id IS NOT NULL AND executor_disclosure IS NOT NULL)"
           )

    execute("""
    CREATE FUNCTION enforce_work_job_step_transition()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        OLD.work_job_id, OLD.sequence, OLD.provider_call_id,
        OLD.provider_item_id, OLD.provider_response_id, OLD.tool_name,
        OLD.tool_version, OLD.module_id, OLD.catalog_digest,
        OLD.argument_digest, OLD.requested_at
      ) IS DISTINCT FROM ROW(
        NEW.work_job_id, NEW.sequence, NEW.provider_call_id,
        NEW.provider_item_id, NEW.provider_response_id, NEW.tool_name,
        NEW.tool_version, NEW.module_id, NEW.catalog_digest,
        NEW.argument_digest, NEW.requested_at
      ) THEN
        RAISE EXCEPTION 'work job step identity is immutable';
      END IF;

      IF OLD.status = 'requested' AND NEW.status NOT IN (
        'requested', 'running', 'succeeded', 'failed', 'refused',
        'cancelled', 'unavailable', 'interrupted'
      ) THEN
        RAISE EXCEPTION 'invalid requested work job step transition';
      END IF;

      IF OLD.status = 'running' AND NEW.status NOT IN (
        'running', 'succeeded', 'failed', 'refused', 'cancelled',
        'unavailable', 'interrupted'
      ) THEN
        RAISE EXCEPTION 'invalid running work job step transition';
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
        RAISE EXCEPTION 'terminal work job step is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER work_job_steps_enforce_transition
    BEFORE UPDATE ON work_job_steps
    FOR EACH ROW
    EXECUTE FUNCTION enforce_work_job_step_transition();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS work_job_steps_enforce_transition ON work_job_steps")
    execute("DROP FUNCTION IF EXISTS enforce_work_job_step_transition()")
    drop table(:work_job_steps)

    execute("DROP TRIGGER IF EXISTS work_jobs_enforce_transition ON work_jobs")
    execute("DROP FUNCTION IF EXISTS enforce_work_job_transition()")
    drop table(:work_jobs)
  end
end
