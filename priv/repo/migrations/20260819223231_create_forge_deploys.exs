defmodule OpenAgents.Repo.Migrations.CreateForgeDeploys do
  use Ecto.Migration

  def change do
    create table(:forge_deploys) do
      add :target_id, references(:forge_fleet_targets, on_delete: :delete_all), null: false
      add :source_sha, :string, null: false
      add :strategy, :string
      add :modules, {:array, :string}, default: "{}"
      add :expected_nodes, {:array, :string}, default: "{}"
      add :per_node_results, :map, null: false, default: "{}"
      add :canary_result, :map
      add :artifact_digest, :string
      add :push_to_live_ms, :integer
      add :terminal_result, :string
      add :duration_ms, :integer
      add :details, :map, null: false, default: "{}"

      timestamps()
    end

    create index(:forge_deploys, [:target_id])
    create index(:forge_deploys, [:source_sha])
  end
end
