defmodule OpenAgents.Repo.Migrations.LinkForgeAssignmentsToWorkJobs do
  use Ecto.Migration

  # A Computer assignment already knows its work job: the delegation payload
  # carries `assignment_id` back the other way. That pointer lives inside a
  # JSONB map, so nothing can ask an issue which jobs ran for it without
  # scanning every work job. This promotes the existing pointer to a typed,
  # indexed column and backfills it from the map it came from. No new work
  # record: the job stays authority for execution, the assignment stays
  # authority for the attempt, and the issue stays the requested outcome.
  def up do
    alter table(:forge_assignments) do
      add :work_job_id, references(:work_jobs, type: :binary_id, on_delete: :nilify_all)
    end

    execute("""
    UPDATE forge_assignments
    SET work_job_id = work_jobs.id
    FROM work_jobs
    WHERE work_jobs.kind = 'delegation'
      AND work_jobs.delegation ->> 'assignment_id' = forge_assignments.id::text
    """)

    create index(:forge_assignments, [:work_job_id])
  end

  def down do
    drop_if_exists index(:forge_assignments, [:work_job_id])

    alter table(:forge_assignments) do
      remove :work_job_id
    end
  end
end
