defmodule OpenAgents.Repo.Migrations.CreateRepositoryPublications do
  use Ecto.Migration

  def change do
    create table(:repository_publications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id,
          references(:repositories, type: :binary_id, on_delete: :delete_all),
          null: false

      add :owner_user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :conversation_id, :binary_id
      add :tool_call_id, :string
      add :workspace_ref, :string, null: false
      add :idempotency_key, :string, null: false
      add :argument_digest, :string, null: false
      add :message, :text, null: false
      add :expected_workspace_digest, :string
      add :observed_workspace_digest, :string
      add :branch, :string, null: false
      add :source_oid, :string
      add :expected_previous_oid, :string
      add :published_oid, :string
      add :state, :string, null: false, default: "requested"
      add :wal_seq, :bigint
      add :result, :map
      add :error_code, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repository_publications, [:idempotency_key])
    create index(:repository_publications, [:repository_id, :workspace_ref, :branch])

    create constraint(:repository_publications, :repository_publications_state_check,
             check:
               "state IN ('requested', 'committing', 'pushing', 'accepted', 'uncertain', " <>
                 "'failed', 'nothing_to_publish')"
           )
  end
end
