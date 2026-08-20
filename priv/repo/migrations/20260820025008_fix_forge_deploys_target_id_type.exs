defmodule OpenAgents.Repo.Migrations.FixForgeDeploysTargetIdType do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE forge_deploys DROP CONSTRAINT IF EXISTS forge_deploys_target_id_fkey")
    execute("ALTER TABLE forge_deploys ALTER COLUMN target_id DROP NOT NULL")

    execute(
      "ALTER TABLE forge_deploys ALTER COLUMN target_id TYPE bigint USING target_id::text::bigint"
    )

    alter table(:forge_deploys) do
      modify :target_id, references(:forge_fleet_targets, type: :id, on_delete: :restrict)
    end
  end

  def down do
    execute("ALTER TABLE forge_deploys DROP CONSTRAINT IF EXISTS forge_deploys_target_id_fkey")

    execute(
      "ALTER TABLE forge_deploys ALTER COLUMN target_id TYPE uuid USING target_id::text::uuid"
    )

    alter table(:forge_deploys) do
      modify :target_id, references(:forge_fleet_targets, type: :binary_id, on_delete: :restrict)
    end
  end
end
