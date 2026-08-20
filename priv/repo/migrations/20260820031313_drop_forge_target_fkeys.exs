defmodule OpenAgents.Repo.Migrations.DropForgeTargetFkeys do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE forge_deploys DROP CONSTRAINT IF EXISTS forge_deploys_target_id_fkey")
    execute("ALTER TABLE forge_builds DROP CONSTRAINT IF EXISTS forge_builds_target_id_fkey")
  end

  def down do
    execute("""
    ALTER TABLE forge_deploys
    ADD CONSTRAINT forge_deploys_target_id_fkey
    FOREIGN KEY (target_id) REFERENCES forge_fleet_targets(id) ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE forge_builds
    ADD CONSTRAINT forge_builds_target_id_fkey
    FOREIGN KEY (target_id) REFERENCES forge_fleet_targets(id) ON DELETE RESTRICT
    """)
  end
end
