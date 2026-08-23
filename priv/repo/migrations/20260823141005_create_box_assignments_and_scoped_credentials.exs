defmodule OpenAgents.Repo.Migrations.CreateBoxAssignmentsAndScopedCredentials do
  use Ecto.Migration

  def change do
    create table(:forge_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_box_id,
          references(:conversation_boxes, type: :binary_id, on_delete: :restrict), null: false

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :restrict),
        null: false

      add :issue_id, references(:issues, on_delete: :restrict), null: false
      add :run_id, references(:box_runs, type: :binary_id, on_delete: :nilify_all)
      add :requesting_principal, :map, null: false
      add :branch, :string, null: false
      add :state, :string, null: false, default: "admitted"
      add :terminal_branch, :string
      add :terminal_commit, :string
      add :failure_reason, :string
      add :deadline_at, :utc_datetime_usec, null: false
      add :admitted_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:forge_assignments, [:conversation_box_id],
             name: :forge_assignments_one_active_box_index,
             where: "state IN ('admitted', 'running')"
           )

    create unique_index(:forge_assignments, [:issue_id],
             name: :forge_assignments_one_active_issue_index,
             where: "state IN ('admitted', 'running')"
           )

    create index(:forge_assignments, [:repository_id, :issue_id])

    create constraint(:forge_assignments, :forge_assignments_state_check,
             check: "state IN ('admitted', 'running', 'completed', 'failed', 'cancelled')"
           )

    create table(:forge_assignment_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :assignment_id,
          references(:forge_assignments, type: :binary_id, on_delete: :delete_all),
          null: false

      add :token_digest, :binary, null: false
      add :last_four, :string, null: false
      add :repository_id, :binary_id, null: false
      add :branch, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:forge_assignment_credentials, [:token_digest])
    create unique_index(:forge_assignment_credentials, [:assignment_id])
    create index(:forge_assignment_credentials, [:expires_at])

    create constraint(:forge_assignment_credentials, :forge_assignment_credentials_digest_length,
             check: "octet_length(token_digest) = 32"
           )
  end
end
