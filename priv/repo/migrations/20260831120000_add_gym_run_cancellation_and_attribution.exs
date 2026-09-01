defmodule OpenAgents.Repo.Migrations.AddGymRunCancellationAndAttribution do
  use Ecto.Migration

  def up do
    # `cancelled` is the operator-declared gradeless terminal state: the run
    # was stopped on purpose, not lost. The staleness sweep only ever touches
    # `running`, so a cancelled row is final the moment it is written.
    drop constraint(:gym_runs, :gym_runs_status_check)

    create constraint(:gym_runs, :gym_runs_status_check,
             check: "status IN ('running', 'graded', 'abandoned', 'cancelled')"
           )

    # Who recorded the run, so `GET /api/v1/gym/runs?mine=true` can answer
    # honestly. Attribution, not ownership: no foreign key, because an account
    # may be deleted while the benchmark record stays — the same posture
    # `gym_trials.thread_id` already takes.
    alter table(:gym_runs) do
      add :recorded_by_user_id, :binary_id
    end

    create index(:gym_runs, [:recorded_by_user_id])
  end

  def down do
    drop index(:gym_runs, [:recorded_by_user_id])

    alter table(:gym_runs) do
      remove :recorded_by_user_id
    end

    # A cancelled run degrades to the nearest legacy meaning: closed without
    # grades.
    execute "UPDATE gym_runs SET status = 'abandoned' WHERE status = 'cancelled'"

    drop constraint(:gym_runs, :gym_runs_status_check)

    create constraint(:gym_runs, :gym_runs_status_check,
             check: "status IN ('running', 'graded', 'abandoned')"
           )
  end
end
