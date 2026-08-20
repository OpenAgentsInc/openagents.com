defmodule OpenAgents.Repo.Migrations.CreateRepositorySecurityControls do
  use Ecto.Migration

  def change do
    create table(:repository_machine_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id,
          references(:repositories, type: :binary_id, on_delete: :delete_all),
          null: false

      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :restrict),
          null: false

      add :operations, {:array, :string}, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repository_machine_grants, [:repository_id, :machine_id])
    create index(:repository_machine_grants, [:machine_id])

    create constraint(:repository_machine_grants, :repository_machine_grants_operations_present,
             check: "cardinality(operations) > 0"
           )

    create constraint(:repository_machine_grants, :repository_machine_grants_operations_allowed,
             check: "operations <@ ARRAY['read', 'write']::varchar[]"
           )

    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_type, :string, null: false
      add :actor_type, :string, null: false
      add :actor_id, :string
      add :subject_type, :string, null: false
      add :subject_id, :string, null: false
      add :repository_id, references(:repositories, type: :binary_id, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_events, [:repository_id, :inserted_at])
    create index(:audit_events, [:event_type, :inserted_at])
    create index(:audit_events, [:actor_type, :actor_id, :inserted_at])

    create constraint(:audit_events, :audit_events_actor_type_allowed,
             check: "actor_type IN ('user', 'machine', 'operator', 'system')"
           )

    create constraint(:audit_events, :audit_events_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )
  end
end
