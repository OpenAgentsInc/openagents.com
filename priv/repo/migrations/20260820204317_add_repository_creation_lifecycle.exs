defmodule OpenAgents.Repo.Migrations.AddRepositoryCreationLifecycle do
  use Ecto.Migration

  @initial_repository_id "00000000-0000-4000-8000-000000000001"
  @initial_namespace_id "00000000-0000-4000-8000-000000000002"
  @openagents_github_id 115_798_681

  def up do
    create table(:namespaces, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :provider, :string, null: false, default: "github"
      add :provider_account_id, :bigint, null: false
      add :provider_node_id, :string
      add :slug, :string, null: false
      add :slug_key, :string, null: false
      add :kind, :string, null: false
      add :owner_user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :provider_refreshed_at, :utc_datetime_usec, null: false
      add :state, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:namespaces, [:provider, :provider_account_id, :kind])

    create unique_index(:namespaces, [:slug_key],
             where: "state = 'active'",
             name: :namespaces_active_slug_key_index
           )

    create constraint(:namespaces, :namespaces_kind_check,
             check: "kind IN ('user', 'organization')"
           )

    create constraint(:namespaces, :namespaces_state_check,
             check: "state IN ('active', 'suspended', 'retired')"
           )

    create constraint(:namespaces, :namespaces_normalized_slug_check,
             check: "slug_key = lower(slug)"
           )

    create constraint(:namespaces, :namespaces_owner_kind_check,
             check:
               "(kind = 'user' AND owner_user_id IS NOT NULL) OR " <>
                 "(kind = 'organization' AND owner_user_id IS NULL)"
           )

    create table(:namespace_aliases, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :namespace_id,
          references(:namespaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :slug, :string, null: false
      add :slug_key, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:namespace_aliases, [:slug_key])

    create constraint(:namespace_aliases, :namespace_aliases_normalized_slug_check,
             check: "slug_key = lower(slug)"
           )

    execute("""
    INSERT INTO namespaces
      (id, provider, provider_account_id, provider_node_id, slug, slug_key, kind,
       provider_refreshed_at, state, inserted_at, updated_at)
    VALUES
      ('#{@initial_namespace_id}', 'github', #{@openagents_github_id}, 'O_kgDOBubymQ',
       'OpenAgentsInc', 'openagentsinc', 'organization', now(), 'active', now(), now())
    """)

    alter table(:repositories) do
      add :namespace_id, references(:namespaces, type: :binary_id, on_delete: :restrict)
      add :description, :string
      add :lifecycle_state, :string, null: false, default: "ready"
      add :provisioning_kind, :string, null: false, default: "empty"
      add :provision_error_code, :string
      add :storage_key, :string
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :ready_at, :utc_datetime_usec
    end

    execute("""
    UPDATE repositories
    SET namespace_id = '#{@initial_namespace_id}',
        storage_key = 'openagents.com',
        ready_at = COALESCE(updated_at, inserted_at)
    WHERE id = '#{@initial_repository_id}'
    """)

    execute("ALTER TABLE repositories ALTER COLUMN namespace_id SET NOT NULL")
    execute("ALTER TABLE repositories ALTER COLUMN storage_key SET NOT NULL")

    drop index(:repositories, [:owner_key, :name_key])
    create unique_index(:repositories, [:namespace_id, :name_key])
    create unique_index(:repositories, [:storage_key])

    create constraint(:repositories, :repositories_lifecycle_state_check,
             check: "lifecycle_state IN ('provisioning', 'ready', 'failed')"
           )

    create constraint(:repositories, :repositories_provisioning_kind_check,
             check: "provisioning_kind IN ('empty', 'github_import')"
           )

    create constraint(:repositories, :repositories_ready_state_check,
             check:
               "(lifecycle_state = 'ready' AND ready_at IS NOT NULL) OR " <>
                 "(lifecycle_state <> 'ready')"
           )

    create table(:repository_imports, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :repository_id,
          references(:repositories, type: :binary_id, on_delete: :delete_all),
          null: false

      add :provider, :string, null: false, default: "github"
      add :source_repository_id, :bigint, null: false
      add :source_owner_id, :bigint, null: false
      add :source_full_name, :string, null: false
      add :source_default_branch, :string, null: false
      add :source_ref_digest, :string, null: false
      add :source_head_sha, :string
      add :source_refs, :map, null: false
      add :source_uses_lfs, :boolean, null: false, default: false
      add :state, :string, null: false, default: "pending"
      add :attempt_count, :integer, null: false, default: 0
      add :error_code, :string
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repository_imports, [:repository_id])

    create constraint(:repository_imports, :repository_imports_state_check,
             check: "state IN ('pending', 'running', 'completed', 'failed')"
           )

    create constraint(:repository_imports, :repository_imports_digest_check,
             check: "source_ref_digest ~ '^[0-9a-f]{64}$'"
           )

    create table(:repository_provisioning_outbox, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :repository_id,
          references(:repositories, type: :binary_id, on_delete: :delete_all),
          null: false

      add :repository_import_id,
          references(:repository_imports, type: :binary_id, on_delete: :delete_all)

      add :operation, :string, null: false
      add :state, :string, null: false, default: "pending"
      add :attempt_count, :integer, null: false, default: 0
      add :retry_at, :utc_datetime_usec, null: false
      add :claimed_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :error_code, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repository_provisioning_outbox, [:repository_id])
    create index(:repository_provisioning_outbox, [:state, :retry_at])

    create constraint(:repository_provisioning_outbox, :repository_provisioning_operation_check,
             check: "operation IN ('create', 'github_import')"
           )

    create constraint(:repository_provisioning_outbox, :repository_provisioning_state_check,
             check: "state IN ('pending', 'running', 'completed', 'failed')"
           )

    create table(:repository_idempotency_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :operation, :string, null: false
      add :idempotency_key, :string, null: false
      add :request_digest, :string, null: false

      add :repository_id,
          references(:repositories, type: :binary_id, on_delete: :delete_all),
          null: false

      add :repository_import_id,
          references(:repository_imports, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repository_idempotency_requests, [
             :user_id,
             :operation,
             :idempotency_key
           ])

    create constraint(:repository_idempotency_requests, :repository_idempotency_digest_check,
             check: "request_digest ~ '^[0-9a-f]{64}$'"
           )
  end

  def down do
    drop table(:repository_idempotency_requests)
    drop table(:repository_provisioning_outbox)
    drop table(:repository_imports)

    drop constraint(:repositories, :repositories_ready_state_check)
    drop constraint(:repositories, :repositories_provisioning_kind_check)
    drop constraint(:repositories, :repositories_lifecycle_state_check)
    drop index(:repositories, [:storage_key])
    drop index(:repositories, [:namespace_id, :name_key])
    create unique_index(:repositories, [:owner_key, :name_key])

    alter table(:repositories) do
      remove :ready_at
      remove :created_by_user_id
      remove :storage_key
      remove :provision_error_code
      remove :provisioning_kind
      remove :lifecycle_state
      remove :description
      remove :namespace_id
    end

    drop table(:namespace_aliases)
    drop table(:namespaces)
  end
end
