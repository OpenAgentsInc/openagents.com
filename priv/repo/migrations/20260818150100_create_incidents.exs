defmodule Sarah.Repo.Migrations.CreateIncidents do
  use Ecto.Migration

  # One durable, queryable home for every anomalous failure across surfaces —
  # turn, tool, voice, job, delegation, controller — so a failure is never again
  # captured "nowhere". Shaped like the receipts/work_jobs tables Sarah already
  # trusts. See docs/audits/2026-08-18-sarah-self-healing-and-error-observability-audit.md.
  def change do
    create table(:incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      add :owner_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :owner_visitor_id, references(:visitors, type: :binary_id, on_delete: :nilify_all)

      # Where the failure happened and who reported it.
      add :surface, :string, null: false
      add :origin, :string, null: false
      # The durable record it points at: a turn_id / tool_step_id / job_id / request_id.
      add :correlation_ref, :string

      # The real machine-readable reason (transport:provider_task_exited, …).
      add :code, :string, null: false
      add :severity, :string, null: false, default: "anomalous"
      add :summary, :string
      # Bounded, secret-scrubbed structured context.
      add :context, :map, null: false, default: %{}

      add :status, :string, null: false, default: "open"
      add :fixer_job_id, references(:work_jobs, type: :binary_id, on_delete: :nilify_all)
      add :receipt_ref, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:incidents, [:owner_user_id])
    create index(:incidents, [:conversation_id])
    create index(:incidents, [:code])
    create index(:incidents, [:severity])
    create index(:incidents, [:status])
    create index(:incidents, [:inserted_at])
  end
end
