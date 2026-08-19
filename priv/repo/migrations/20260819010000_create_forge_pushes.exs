defmodule Sarah.Repo.Migrations.CreateForgePushes do
  use Ecto.Migration

  def change do
    create table(:forge_pushes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repo, :string, null: false
      add :wal_seq, :integer, null: false
      add :principal, :string, null: false
      add :refs, :map, null: false, default: %{}
      add :duration_ms, :integer
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:forge_pushes, [:repo, :wal_seq])
    create index(:forge_pushes, [:repo, :inserted_at])
  end
end
