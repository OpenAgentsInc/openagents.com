defmodule OpenAgents.Repo.Migrations.CreateScvRuns do
  use Ecto.Migration

  def change do
    create table(:scv_runs, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :driver_account_id,
          references(:scv_driver_accounts, type: :uuid, on_delete: :restrict),
          null: false

      add :issue_id, references(:issues, on_delete: :nilify_all)
      add :driver, :string, null: false
      add :principal, :string, null: false
      add :repository_revision, :string, null: false
      add :objective, :text, null: false
      add :permission_profile, :string, null: false
      add :model, :string, null: false
      add :reasoning_effort, :string, null: false
      add :status, :string, null: false
      add :owner_node, :string, null: false
      add :generation, :bigint, null: false
      add :lease_expires_at, :utc_datetime_usec, null: false
      add :driver_thread_id, :string
      add :driver_turn_id, :string
      add :report, :text
      add :report_digest, :string
      add :event_count, :integer, null: false, default: 0
      add :usage, :map
      add :resources, :map
      add :error_code, :string
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scv_runs, [:issue_id, :inserted_at])
    create index(:scv_runs, [:status, :lease_expires_at])

    create unique_index(:scv_runs, [:driver_account_id],
             where: "status = 'running'",
             name: :scv_runs_one_active_account_index
           )

    create unique_index(:scv_runs, [:driver_account_id, :generation])

    create constraint(:scv_runs, :scv_runs_driver_check, check: "driver IN ('codex_app_server')")

    create constraint(:scv_runs, :scv_runs_permission_profile_check,
             check: "permission_profile IN ('read_only')"
           )

    create constraint(:scv_runs, :scv_runs_reasoning_effort_check,
             check: "reasoning_effort IN ('none', 'low')"
           )

    create constraint(:scv_runs, :scv_runs_status_check,
             check: "status IN ('running', 'succeeded', 'failed', 'cancelled', 'uncertain')"
           )

    create constraint(:scv_runs, :scv_runs_repository_revision_check,
             check: "repository_revision ~ '^[0-9a-f]{40}$'"
           )

    create constraint(:scv_runs, :scv_runs_objective_bound_check,
             check: "octet_length(objective) BETWEEN 1 AND 32768"
           )

    create constraint(:scv_runs, :scv_runs_report_bound_check,
             check: "report IS NULL OR octet_length(report) BETWEEN 1 AND 32768"
           )

    create table(:scv_run_events) do
      add :run_id, references(:scv_runs, type: :uuid, on_delete: :delete_all), null: false
      add :schema, :string, null: false
      add :event_type, :string, null: false
      add :payload, :map, null: false
      add :emitted_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:scv_run_events, [:run_id, :id])

    create constraint(:scv_run_events, :scv_run_events_schema_check,
             check: "schema = 'openagents.scv.event.v1'"
           )

    create constraint(:scv_run_events, :scv_run_events_payload_bound_check,
             check: "octet_length(payload::text) BETWEEN 2 AND 16384"
           )
  end
end
