defmodule OpenAgents.Repo.Migrations.CreateGymRuns do
  use Ecto.Migration

  def change do
    create table(:gym_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :suite, :text, null: false
      add :agent, :text, null: false
      add :agent_version, :text
      add :model, :text, null: false
      add :lane, :text
      add :tasks_total, :integer, null: false
      add :tasks_passed, :integer, null: false
      add :input_tokens, :bigint
      add :output_tokens, :bigint
      add :cost_microusd, :bigint
      add :duration_seconds, :integer
      add :recipe_digest, :text, null: false
      add :report, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:gym_runs, :gym_runs_task_counts_check,
             check: "tasks_total >= 0 AND tasks_passed >= 0 AND tasks_passed <= tasks_total"
           )

    create constraint(:gym_runs, :gym_runs_suite_bound_check,
             check: "octet_length(suite) BETWEEN 1 AND 200"
           )

    create constraint(:gym_runs, :gym_runs_agent_bound_check,
             check: "octet_length(agent) BETWEEN 1 AND 200"
           )

    create constraint(:gym_runs, :gym_runs_model_bound_check,
             check: "octet_length(model) BETWEEN 1 AND 200"
           )

    create constraint(:gym_runs, :gym_runs_recipe_digest_bound_check,
             check: "octet_length(recipe_digest) BETWEEN 1 AND 200"
           )

    # One row per exact run of an exact recipe: a re-submitted result replays
    # rather than duplicating, so trend lines never double-count a run.
    create unique_index(:gym_runs, [:recipe_digest])

    create index(:gym_runs, [:suite, :inserted_at])
  end
end
