defmodule OpenAgents.Repo.Migrations.CreateForgeBuilds do
  use Ecto.Migration

  def change do
    create table(:forge_builds) do
      add :target_id, references(:forge_fleet_targets, on_delete: :delete_all), null: false
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
