defmodule OpenAgents.Repo.Migrations.CreateBoxRuns do
  use Ecto.Migration

  def change do
    create table(:box_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :conversation_box_id,
          references(:conversation_boxes, type: :binary_id, on_delete: :restrict),
          null: false

      add :requesting_principal, :map, null: false
      add :command, :text, null: false
      add :idempotency_key, :string, null: false
      add :state, :string, null: false, default: "admitted"
      add :exit_status, :integer
      add :timed_out, :boolean, null: false, default: false
      add :output, :text, null: false, default: ""
      add :output_base_offset, :integer, null: false, default: 0
      add :last_output_offset, :integer, null: false, default: 0
      add :pid, :integer
      add :run_directory, :string, null: false
      add :failure_reason, :string
      add :dispatch_attempted_at, :utc_datetime_usec
      add :probe_attempted_at, :utc_datetime_usec
      add :admitted_at, :utc_datetime_usec, null: false
      add :dispatched_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :cancellation_requested_at, :utc_datetime_usec
      add :cancellation_effective_at, :utc_datetime_usec
      add :deadline_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:box_runs, [:conversation_id, :idempotency_key])

    create unique_index(:box_runs, [:conversation_box_id],
             name: :box_runs_one_active_per_box_index,
             where: "state IN ('admitted', 'dispatched', 'running')"
           )

    create index(:box_runs, [:conversation_id, :inserted_at])
    create index(:box_runs, [:state])

    create constraint(:box_runs, :box_runs_state_check,
             check:
               "state IN ('admitted', 'dispatched', 'running', 'completed', 'failed', 'cancelled', 'timed_out', 'lost')"
           )

    create constraint(:box_runs, :box_runs_offsets_check,
             check: "output_base_offset >= 0 AND last_output_offset >= output_base_offset"
           )
  end
end
