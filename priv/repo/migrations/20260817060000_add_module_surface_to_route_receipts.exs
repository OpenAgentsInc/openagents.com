defmodule Sarah.Repo.Migrations.AddModuleSurfaceToRouteReceipts do
  use Ecto.Migration

  def up do
    alter table(:module_route_receipts) do
      add :surface, :string, null: false, default: "text"
    end

    create constraint(:module_route_receipts, :module_route_receipt_surface_check,
             check: "surface IN ('text','voice','search','computer','repository','mcp','agent')"
           )
  end

  def down do
    alter table(:module_route_receipts) do
      remove :surface
    end
  end
end
