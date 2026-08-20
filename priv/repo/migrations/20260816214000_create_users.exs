defmodule OpenAgents.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :github_id, :bigint, null: false
      add :github_login, :string, null: false
      add :github_name, :string
      add :github_avatar_url, :string, null: false
      add :status, :string, null: false, default: "active"
      add :banned_at, :utc_datetime_usec
      add :ban_reason_code, :string
      add :last_authenticated_at, :utc_datetime_usec
      add :github_token_ciphertext, :binary

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:github_id])
  end
end
