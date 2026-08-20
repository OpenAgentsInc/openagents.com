defmodule OpenAgents.Repo.Migrations.AlignForgeBuildsAndTargets do
  @moduledoc """
  Aligns the deploy-lane tables with the schemas that actually read them.

  `forge_builds` was created in an earlier, unrelated shape (bigserial id,
  `source_sha`, `toolchain_identity`, `module_changes`, `artifact_path`,
  `artifact_digest`, `output`). No module ever mapped to those columns —
  `OpenAgents.Forge.BuildReceipt` maps `{repo, sha, target_id, modules,
  warnings, tests, duration_ms, artifact}` — so every build receipt insert
  raised, the Builder rescued it as "builder crashed", and the deploy lane
  could never reach `built`. The table has no readers or writers, so it is
  recreated in the shape the receipt requires, with the idempotency index
  (`{repo, sha, target_id}`) the Builder's `on_conflict` names.

  `forge_fleet_targets` got second-resolution timestamps from a bare
  `timestamps()`. `OpenAgents.Forge.Targets.current/1` is "newest row for
  this repo", so any two promotions inside the same second tie and the
  current fleet target becomes arbitrary — a pin-back could silently fail
  to take effect. The schema declares `utc_datetime_usec`; the columns now
  match. The status check constraint that `Target.changeset/2` names is
  added here too, so an illegal status is refused by the database and
  surfaces as a changeset error rather than a silent write.
  """

  use Ecto.Migration

  def up do
    drop table(:forge_builds)

    create table(:forge_builds, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repo, :string, null: false
      add :sha, :string, null: false
      add :target_id, :binary_id, null: false
      add :modules, {:array, :string}, null: false, default: []
      add :warnings, :text
      add :tests, :text
      add :duration_ms, :integer
      add :artifact, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:forge_builds, [:repo, :sha, :target_id])
    create index(:forge_builds, [:repo, :inserted_at])

    execute("""
    ALTER TABLE forge_fleet_targets
      ALTER COLUMN inserted_at TYPE timestamp(6) without time zone,
      ALTER COLUMN updated_at TYPE timestamp(6) without time zone
    """)

    create index(:forge_fleet_targets, [:repo, :inserted_at])

    create constraint(:forge_fleet_targets, :forge_fleet_target_status,
             check:
               "status IN ('promoted','building','built','deploying','live','failed','reverted','needs_rolling_replace')"
           )
  end

  def down do
    drop constraint(:forge_fleet_targets, :forge_fleet_target_status)
    drop index(:forge_fleet_targets, [:repo, :inserted_at])

    execute("""
    ALTER TABLE forge_fleet_targets
      ALTER COLUMN inserted_at TYPE timestamp(0) without time zone,
      ALTER COLUMN updated_at TYPE timestamp(0) without time zone
    """)

    drop table(:forge_builds)

    create table(:forge_builds) do
      add :target_id, :uuid, null: false
      add :source_sha, :string, null: false
      add :toolchain_identity, :string
      add :baseline_sha, :string
      add :module_changes, :map, null: false, default: "{}"
      add :artifact_path, :string
      add :artifact_digest, :string
      add :output, :text
      add :duration_ms, :integer
      add :details, :map, null: false, default: "{}"

      timestamps()
    end

    create index(:forge_builds, [:target_id])
    create index(:forge_builds, [:source_sha])
  end
end
