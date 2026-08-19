defmodule Sarah.Repo.Migrations.CreateMachines do
  use Ecto.Migration

  def change do
    create table(:machines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :tier, :string, null: false, default: "probe"
      add :platform, :string
      add :agent_version, :string
      add :roots, {:array, :text}, null: false, default: []
      add :token_digest, :binary, null: false
      add :status, :string, null: false, default: "active"
      add :revoked_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
      add :last_probe, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:machines, [:token_digest])
    create index(:machines, [:user_id])

    create constraint(:machines, :machines_tier_check,
             check: "tier IN ('probe', 'curated', 'shell')"
           )

    create constraint(:machines, :machines_status_check, check: "status IN ('active', 'revoked')")

    create table(:machine_pairings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code_digest, :binary, null: false
      add :poll_secret_digest, :binary, null: false
      add :name, :string, null: false
      add :tier, :string, null: false, default: "probe"
      add :platform, :string
      add :agent_version, :string
      add :roots, {:array, :text}, null: false, default: []
      add :status, :string, null: false, default: "pending"
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all)
      add :token_ciphertext, :binary
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:machine_pairings, [:code_digest])
    create index(:machine_pairings, [:expires_at])

    create constraint(:machine_pairings, :machine_pairings_tier_check,
             check: "tier IN ('probe', 'curated', 'shell')"
           )

    create constraint(:machine_pairings, :machine_pairings_status_check,
             check: "status IN ('pending', 'approved', 'claimed', 'expired')"
           )
  end
end
