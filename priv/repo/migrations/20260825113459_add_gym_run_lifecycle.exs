defmodule OpenAgents.Repo.Migrations.AddGymRunLifecycle do
  use Ecto.Migration

  def up do
    # A run now exists while it runs. `status` defaults to `graded` so every
    # legacy row — recorded only after the fact — keeps the meaning it had,
    # and `updated_at`/`completed_at` are backfilled from `inserted_at` for
    # the same reason: a one-shot row was complete the moment it was written.
    alter table(:gym_runs) do
      add :status, :text, null: false, default: "graded"
      add :completed_at, :utc_datetime_usec
      add :updated_at, :utc_datetime_usec
    end

    execute "UPDATE gym_runs SET updated_at = inserted_at, completed_at = inserted_at"

    execute "ALTER TABLE gym_runs ALTER COLUMN updated_at SET NOT NULL"

    # A running row has no grades yet; the changeset requires them by status
    # and the constraint below keeps a graded row honest at the database.
    execute "ALTER TABLE gym_runs ALTER COLUMN tasks_total DROP NOT NULL"
    execute "ALTER TABLE gym_runs ALTER COLUMN tasks_passed DROP NOT NULL"

    create constraint(:gym_runs, :gym_runs_status_check,
             check: "status IN ('running', 'graded', 'abandoned')"
           )

    create constraint(:gym_runs, :gym_runs_graded_shape_check,
             check:
               "status <> 'graded' OR (tasks_total IS NOT NULL AND tasks_passed IS NOT NULL AND completed_at IS NOT NULL)"
           )

    # The lazy staleness sweep reads exactly this slice.
    create index(:gym_runs, [:updated_at], where: "status = 'running'")

    create table(:gym_trials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:gym_runs, type: :binary_id, on_delete: :delete_all), null: false

      add :task, :text, null: false
      add :state, :text, null: false
      add :thread_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:gym_trials, :gym_trials_task_bound_check,
             check: "octet_length(task) BETWEEN 1 AND 200"
           )

    create constraint(:gym_trials, :gym_trials_state_check,
             check: "state IN ('running', 'passed', 'failed', 'ungraded')"
           )

    # One row per task per run: a re-reported trial updates in place.
    create unique_index(:gym_trials, [:run_id, :task])
  end

  def down do
    drop table(:gym_trials)

    drop index(:gym_runs, [:updated_at], where: "status = 'running'")
    drop constraint(:gym_runs, :gym_runs_graded_shape_check)
    drop constraint(:gym_runs, :gym_runs_status_check)

    execute "DELETE FROM gym_runs WHERE tasks_total IS NULL OR tasks_passed IS NULL"
    execute "ALTER TABLE gym_runs ALTER COLUMN tasks_total SET NOT NULL"
    execute "ALTER TABLE gym_runs ALTER COLUMN tasks_passed SET NOT NULL"

    alter table(:gym_runs) do
      remove :status
      remove :completed_at
      remove :updated_at
    end
  end
end
