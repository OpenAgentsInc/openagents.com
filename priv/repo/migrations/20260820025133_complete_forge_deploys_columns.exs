defmodule OpenAgents.Repo.Migrations.CompleteForgeDeploysColumns do
  use Ecto.Migration

  def up do
    for {column, type, opts} <- missing_columns() do
      add_column?(column, type, opts)
    end
  end

  def down do
    # No safe down path for idempotent column additions.
  end

  defp missing_columns do
    [
      {:result, :string, null: false},
      {:canary, :string, []},
      {:push_to_live_ms, :integer, []},
      {:nodes, {:array, :string}, null: false, default: []}
    ]
  end

  defp add_column?(column, type, opts) do
    case repo().query("""
         SELECT 1 FROM information_schema.columns
         WHERE table_name = 'forge_deploys' AND column_name = '#{column}'
         """) do
      {:ok, %{num_rows: 0}} ->
        alter table(:forge_deploys) do
          add column, type, opts
        end

      _ ->
        :ok
    end
  end
end
