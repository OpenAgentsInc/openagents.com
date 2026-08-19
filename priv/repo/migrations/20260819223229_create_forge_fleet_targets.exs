defmodule OpenAgents.Repo.Migrations.CreateForgeFleetTargets do
  use Ecto.Migration

  def change do
    create table(:forge_fleet_targets) do
      add :repo, :string, null: false
      add :sha, :string, null: false
      add :promoted_by, :string, null: false
      add :strategy, :string
      add :status, :string, null: false, default: "promoted"
      add :details, :map, null: false, default: "{}"

      timestamps()
    end

    create index(:forge_fleet_targets, [:repo, :sha])
    create index(:forge_fleet_targets, [:status])
    create index(:forge_fleet_targets, [:inserted_at])
  end
end
