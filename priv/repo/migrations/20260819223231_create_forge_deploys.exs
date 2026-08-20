defmodule OpenAgents.Repo.Migrations.CreateForgeDeploys do
  use Ecto.Migration

  def change do
    create table(:forge_deploys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repo, :string, null: false
      add :sha, :string, null: false
      add :target_id, :binary_id, null: false
      add :modules, {:array, :string}, null: false, default: []
      add :nodes, {:array, :string}, null: false, default: []
      add :result, :string, null: false
      add :canary, :string
      add :push_to_live_ms, :integer
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:forge_deploys, [:repo, :inserted_at])

    create constraint(:forge_deploys, :forge_deploys_result,
             check: "result IN ('live','reverted','needs_rolling_replace','failed')"
           )
  end
end
