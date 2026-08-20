defmodule OpenAgents.Repo.Migrations.HardenForgeBuildAttemptReceipts do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:forge_builds, [:repo, :sha, :target_id])

    alter table(:forge_builds) do
      add :status, :string, null: false, default: "complete"
      add :baseline_manifest, :map
      add :manifest, :map
      add :artifact_digest, :string
      add :output_digest, :string
      add :output_ref, :string
      add :error_code, :string
      add :completed_at, :utc_datetime_usec
      add :updated_at, :utc_datetime_usec
    end

    execute(
      "UPDATE forge_builds SET completed_at = inserted_at, updated_at = inserted_at WHERE completed_at IS NULL",
      "SELECT 1"
    )

    create index(:forge_builds, [:target_id, :inserted_at])
    create index(:forge_builds, [:repo, :status, :inserted_at])

    create unique_index(:forge_builds, [:target_id],
             where: "status = 'running'",
             name: :forge_builds_one_running_attempt_per_target
           )

    create constraint(:forge_builds, :forge_builds_status_allowed,
             check: "status IN ('running', 'complete', 'failed', 'expired')"
           )

    create constraint(:forge_builds, :forge_builds_artifact_digest_shape,
             check: "artifact_digest IS NULL OR artifact_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:forge_builds, :forge_builds_output_digest_shape,
             check: "output_digest IS NULL OR output_digest ~ '^[0-9a-f]{64}$'"
           )
  end
end
