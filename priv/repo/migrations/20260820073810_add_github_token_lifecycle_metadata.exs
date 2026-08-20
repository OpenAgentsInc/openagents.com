defmodule OpenAgents.Repo.Migrations.AddGithubTokenLifecycleMetadata do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :github_token_key_id, :string
      add :github_token_scopes, {:array, :string}, null: false, default: []
      add :github_token_connected_at, :utc_datetime_usec
      add :github_token_rotated_at, :utc_datetime_usec
    end

    execute("""
    UPDATE users
    SET github_token_key_id = 'legacy-v1',
        github_token_scopes = ARRAY['read:user', 'repo'],
        github_token_connected_at = COALESCE(updated_at, inserted_at)
    WHERE github_token_ciphertext IS NOT NULL
    """)

    create constraint(:users, :users_github_token_connection_state_check,
             check: """
             (github_token_ciphertext IS NULL AND github_token_key_id IS NULL AND
              github_token_connected_at IS NULL AND github_token_scopes = '{}') OR
             (github_token_ciphertext IS NOT NULL AND github_token_key_id IS NOT NULL AND
              github_token_connected_at IS NOT NULL AND cardinality(github_token_scopes) > 0)
             """
           )
  end

  def down do
    drop constraint(:users, :users_github_token_connection_state_check)

    alter table(:users) do
      remove :github_token_key_id
      remove :github_token_scopes
      remove :github_token_connected_at
      remove :github_token_rotated_at
    end
  end
end
