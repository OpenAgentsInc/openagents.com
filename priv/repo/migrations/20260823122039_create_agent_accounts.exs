defmodule OpenAgents.Repo.Migrations.CreateAgentAccounts do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :handle, :string, null: false
      add :display_name, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "active"
      add :suspended_at, :utc_datetime_usec
      add :suspension_reason, :string
      add :registration_ip_digest, :binary, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, ["lower(handle)"], name: :agents_lower_handle_index)
    create index(:agents, [:registration_ip_digest, :inserted_at])

    create constraint(:agents, :agents_status_check, check: "status IN ('active', 'suspended')")

    create constraint(:agents, :agents_handle_check,
             check: "handle = lower(handle) AND handle ~ '^[a-z0-9]+(-[a-z0-9]+)*$'"
           )

    create table(:agent_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_digest, :binary, null: false
      add :last_four, :string, null: false
      add :scopes, {:array, :string}, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_tokens, [:token_digest])
    create index(:agent_tokens, [:agent_id, :inserted_at])

    create constraint(:agent_tokens, :agent_tokens_scopes_present,
             check: "cardinality(scopes) > 0"
           )

    create constraint(:agent_tokens, :agent_tokens_scopes_allowed,
             check: "scopes <@ ARRAY['agent:participate']::varchar[]"
           )

    create constraint(:agent_tokens, :agent_tokens_expiry_after_creation,
             check: "expires_at > inserted_at"
           )

    create constraint(:agent_tokens, :agent_tokens_digest_length,
             check: "octet_length(token_digest) = 32"
           )

    create table(:agent_user_links, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :proof_method, :string
      add :proof_evidence, :map
      add :linked_at, :utc_datetime_usec
      add :rejected_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_user_links, [:agent_id, :user_id])

    create unique_index(:agent_user_links, [:agent_id],
             where: "status = 'linked'",
             name: :agent_user_links_one_linked_agent_index
           )

    create constraint(:agent_user_links, :agent_user_links_status_check,
             check: "status IN ('pending', 'linked', 'rejected', 'unlinked')"
           )

    alter table(:issues) do
      add :author_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:comments) do
      add :author_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:issues, [:author_agent_id])
    create index(:comments, [:author_agent_id])

    create constraint(:issues, :issues_one_author_principal_check,
             check: "NOT (author_user_id IS NOT NULL AND author_agent_id IS NOT NULL)"
           )

    create constraint(:comments, :comments_one_author_principal_check,
             check: "NOT (author_user_id IS NOT NULL AND author_agent_id IS NOT NULL)"
           )

    drop constraint(:audit_events, :audit_events_actor_type_allowed)

    create constraint(:audit_events, :audit_events_actor_type_allowed,
             check: "actor_type IN ('user', 'agent', 'machine', 'operator', 'system')"
           )
  end
end
