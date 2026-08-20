defmodule OpenAgents.Repo.Migrations.FixForgeDeploysTargetIdToBinary do
  use Ecto.Migration

  def up do
    # The original openagents.com migration created forge_fleet_targets with an
    # implicit integer primary key, but the OpenAgents.Forge.Target schema uses
    # :binary_id. Switch both the targets and deploys tables to uuid so the
    # foreign key matches the schema.
    execute("TRUNCATE TABLE forge_deploys RESTART IDENTITY CASCADE")
    execute("TRUNCATE TABLE forge_fleet_targets RESTART IDENTITY CASCADE")

    execute("ALTER TABLE forge_fleet_targets DROP COLUMN IF EXISTS id CASCADE")
    execute("ALTER TABLE forge_fleet_targets ADD COLUMN id uuid DEFAULT gen_random_uuid() PRIMARY KEY")

    execute("ALTER TABLE forge_deploys DROP CONSTRAINT IF EXISTS forge_deploys_target_id_fkey")
    execute("ALTER TABLE forge_deploys ALTER COLUMN target_id TYPE uuid USING target_id::text::uuid")
    execute("ALTER TABLE forge_builds ALTER COLUMN target_id TYPE uuid USING target_id::text::uuid")

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

  def down do
    execute("TRUNCATE TABLE forge_deploys RESTART IDENTITY CASCADE")
    execute("TRUNCATE TABLE forge_fleet_targets RESTART IDENTITY CASCADE")

    execute("ALTER TABLE forge_fleet_targets DROP COLUMN IF EXISTS id")
    execute("ALTER TABLE forge_fleet_targets ADD COLUMN id bigserial PRIMARY KEY")

    execute("ALTER TABLE forge_deploys DROP CONSTRAINT IF EXISTS forge_deploys_target_id_fkey")
    execute("ALTER TABLE forge_deploys ALTER COLUMN target_id TYPE bigint USING target_id::text::bigint")

    execute("""
    ALTER TABLE forge_deploys
    ADD CONSTRAINT forge_deploys_target_id_fkey
    FOREIGN KEY (target_id) REFERENCES forge_fleet_targets(id) ON DELETE RESTRICT
    """)
  end
end
