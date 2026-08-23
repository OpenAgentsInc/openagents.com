defmodule OpenAgents.Repo.Migrations.CreatePullRequestStacks do
  use Ecto.Migration

  def change do
    create table(:pull_request_stacks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :number, :bigint, null: false
      add :trunk_ref, :string, null: false
      add :state, :string, null: false, default: "open"
      add :health, :string, null: false, default: "healthy"
      add :version, :bigint, null: false, default: 1
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pull_request_stacks, [:repository_id, :number])

    create constraint(:pull_request_stacks, :pull_request_stacks_state_check,
             check: "state IN ('open', 'completed', 'dissolved')"
           )

    create constraint(:pull_request_stacks, :pull_request_stacks_health_check,
             check:
               "health IN ('healthy', 'needs_rebase', 'conflicted', 'missing_ref', 'head_changed', 'policy_blocked', 'operation_in_progress')"
           )

    create constraint(:pull_request_stacks, :pull_request_stacks_version_check,
             check: "version >= 1"
           )

    create constraint(:pull_request_stacks, :pull_request_stacks_number_check,
             check: "number >= 1"
           )

    create table(:pull_request_stack_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :stack_id,
          references(:pull_request_stacks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :pull_request_id, references(:pull_requests, type: :binary_id, on_delete: :restrict),
        null: false

      add :position, :integer, null: false
      add :boundary_oid, :bytea, null: false
      add :observed_head_oid, :bytea, null: false
      add :removed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:pull_request_stack_entries, [:stack_id])
    create index(:pull_request_stack_entries, [:pull_request_id])

    create unique_index(:pull_request_stack_entries, [:stack_id, :position],
             where: "removed_at IS NULL",
             name: :pull_request_stack_entries_active_position_index
           )

    create unique_index(:pull_request_stack_entries, [:pull_request_id],
             where: "removed_at IS NULL",
             name: :pull_request_stack_entries_active_pull_request_index
           )

    create constraint(:pull_request_stack_entries, :pull_request_stack_entries_position_check,
             check: "position >= 1"
           )

    create constraint(
             :pull_request_stack_entries,
             :pull_request_stack_entries_boundary_oid_check,
             check: "octet_length(boundary_oid) IN (20, 32)"
           )

    create constraint(
             :pull_request_stack_entries,
             :pull_request_stack_entries_observed_head_oid_check,
             check: "octet_length(observed_head_oid) IN (20, 32)"
           )
  end
end
