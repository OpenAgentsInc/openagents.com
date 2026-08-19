defmodule OpenAgents.Repo.Migrations.CreateGithubOauthAttempts do
  use Ecto.Migration

  def change do
    create table(:github_oauth_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :state_digest, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:github_oauth_attempts, [:state_digest])
    create index(:github_oauth_attempts, [:expires_at])
  end
end
