defmodule OpenAgents.Repo.Migrations.FixForgeBuildsTargetIdToBinary do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE forge_builds DROP CONSTRAINT IF EXISTS forge_builds_target_id_fkey")
    execute("ALTER TABLE forge_builds ALTER COLUMN target_id TYPE uuid USING target_id::text::uuid")

    execute("""
    ALTER TABLE forge_builds
    ADD CONSTRAINT forge_builds_target_id_fkey
    FOREIGN KEY (target_id) REFERENCES forge_fleet_targets(id) ON DELETE RESTRICT
    """)
  end

  def down do
    execute("ALTER TABLE forge_builds DROP CONSTRAINT IF EXISTS forge_builds_target_id_fkey")
    execute("ALTER TABLE forge_builds ALTER COLUMN target_id TYPE bigint USING target_id::text::bigint")

    execute("""
    ALTER TABLE forge_builds
    ADD CONSTRAINT forge_builds_target_id_fkey
    FOREIGN KEY (target_id) REFERENCES forge_fleet_targets(id) ON DELETE RESTRICT
    """)
  end
end
