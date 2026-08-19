defmodule Sarah.Repo.Migrations.AddKindAndDelegationToWorkJobs do
  use Ecto.Migration

  # A job can now be a durable computer delegation, not only a deep-work LLM
  # loop. `kind` selects the execution path; `delegation` carries the bounded
  # delegation parameters (agent, machine, prompt, cwd, resume). This lets a
  # delegation run in the background so several run at once and the composer
  # never blocks (#95).
  def change do
    alter table(:work_jobs) do
      add :kind, :string, null: false, default: "deep_work"
      add :delegation, :map
    end

    create index(:work_jobs, [:kind])
  end
end
