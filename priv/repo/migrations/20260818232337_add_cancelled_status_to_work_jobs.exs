defmodule Sarah.Repo.Migrations.AddCancelledStatusToWorkJobs do
  use Ecto.Migration

  def up do
    drop constraint(:work_jobs, :work_jobs_status_check)
    drop constraint(:work_jobs, :work_jobs_terminal_report_check)

    create constraint(:work_jobs, :work_jobs_status_check,
             check:
               "status IN ('queued', 'running', 'completed', 'failed', 'interrupted', 'budget_exhausted', 'cancelled')"
           )

    create constraint(:work_jobs, :work_jobs_terminal_report_check,
             check:
               "(status IN ('queued', 'running') AND completed_at IS NULL) OR (status IN ('completed', 'failed', 'interrupted', 'budget_exhausted', 'cancelled') AND completed_at IS NOT NULL AND report IS NOT NULL AND report <> '')"
           )

    execute("""
    CREATE OR REPLACE FUNCTION enforce_work_job_transition()
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
        'queued', 'running', 'failed', 'interrupted', 'cancelled'
      ) THEN
        RAISE EXCEPTION 'invalid queued work job transition';
      END IF;

      IF OLD.status = 'running' AND NEW.status NOT IN (
        'running', 'completed', 'failed', 'interrupted', 'budget_exhausted', 'cancelled'
      ) THEN
        RAISE EXCEPTION 'invalid running work job transition';
      END IF;

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
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION enforce_work_job_transition()
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

    drop constraint(:work_jobs, :work_jobs_status_check)
    drop constraint(:work_jobs, :work_jobs_terminal_report_check)

    create constraint(:work_jobs, :work_jobs_status_check,
             check:
               "status IN ('queued', 'running', 'completed', 'failed', 'interrupted', 'budget_exhausted')"
           )

    create constraint(:work_jobs, :work_jobs_terminal_report_check,
             check:
               "(status IN ('queued', 'running') AND completed_at IS NULL) OR (status IN ('completed', 'failed', 'interrupted', 'budget_exhausted') AND completed_at IS NOT NULL AND report IS NOT NULL AND report <> '')"
           )
  end
end
