defmodule Sarah.Repo.Migrations.AllowGraphReceiptPrivacyDeletion do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION reject_graph_projection_update()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' AND TG_TABLE_NAME = 'graph_operation_receipts' AND
         NOT EXISTS (SELECT 1 FROM visitors WHERE id = OLD.owner_visitor_id)
      THEN
        RETURN OLD;
      END IF;
      RAISE EXCEPTION 'graph projections are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION reject_graph_projection_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'graph projections are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)
  end
end
