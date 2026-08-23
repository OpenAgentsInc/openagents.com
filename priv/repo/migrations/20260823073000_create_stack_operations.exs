defmodule OpenAgents.Repo.Migrations.CreateStackOperations do
  use Ecto.Migration

  def change do
    create table(:stack_operations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :stack_id,
          references(:pull_request_stacks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :kind, :string, null: false
      add :state, :string, null: false, default: "pending"
      add :target_position, :integer
      add :expected_stack_version, :bigint, null: false
      add :idempotency_key, :string, null: false

      add :request, :map, null: false, default: %{}
      add :snapshot, :map
      add :planned_result, :map
      add :conflict, :map
      add :error, :map

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :attempt_count, :integer, null: false, default: 0
      add :retry_at, :utc_datetime_usec
      add :claimed_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stack_operations, [:stack_id, :idempotency_key])

    create unique_index(:stack_operations, [:stack_id],
             where: "state IN ('pending', 'running', 'waiting_for_conflict_resolution')",
             name: :stack_operations_active_stack_index
           )

    create index(:stack_operations, [:state, :retry_at])

    create constraint(:stack_operations, :stack_operations_kind_check,
             check:
               "kind IN ('create', 'append', 'restructure', 'rebase', 'merge', 'queue', 'unstack', 'dissolve', 'repair')"
           )

    create constraint(:stack_operations, :stack_operations_state_check,
             check:
               "state IN ('pending', 'running', 'waiting_for_conflict_resolution', 'waiting_for_checks', 'succeeded', 'partially_succeeded', 'failed', 'cancelled')"
           )
  end
end
