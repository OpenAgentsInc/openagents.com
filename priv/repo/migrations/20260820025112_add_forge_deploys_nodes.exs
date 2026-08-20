defmodule OpenAgents.Repo.Migrations.AddForgeDeploysNodes do
  use Ecto.Migration

  def up do
    unless has_column?(:forge_deploys, :nodes) do
      alter table(:forge_deploys) do
        add :nodes, {:array, :string}, null: false, default: []
      end
    end
  end

  def down do
    if has_column?(:forge_deploys, :nodes) do
      alter table(:forge_deploys) do
        remove :nodes
      end
    end
  end

  defp has_column?(table, column) do
    table_exists? =
      case repo().query("SELECT 1 FROM pg_tables WHERE tablename = '#{table}'") do
        {:ok, %{num_rows: n}} -> n > 0
        _ -> false
      end

    if table_exists? do
      case repo().query(
             "SELECT 1 FROM information_schema.columns WHERE table_name = '#{table}' AND column_name = '#{column}'"
           ) do
        {:ok, %{num_rows: n}} -> n > 0
        _ -> false
      end
    else
      false
    end
  end
end
