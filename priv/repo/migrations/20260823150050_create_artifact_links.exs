defmodule OpenAgents.Repo.Migrations.CreateArtifactLinks do
  use Ecto.Migration

  def change do
    create table(:artifact_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:users, type: :binary_id, on_delete: :nothing), null: false

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :nothing),
        null: false

      add :artifact_type, :string, null: false
      add :artifact_ref, :string, null: false
      add :tier, :string, null: false
      add :consent, :map, null: false, default: %{}
      add :authority_snapshot, :map, null: false, default: %{}
      add :revoked_at, :utc_datetime_usec
      add :revocation_tombstone, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:artifact_links, [:account_id])
    create index(:artifact_links, [:repository_id])
    create index(:artifact_links, [:artifact_type, :artifact_ref])

    create constraint(:artifact_links, :artifact_links_tier_check,
             check: "tier IN ('dark','pulse','ledger','glass')"
           )
  end
end
