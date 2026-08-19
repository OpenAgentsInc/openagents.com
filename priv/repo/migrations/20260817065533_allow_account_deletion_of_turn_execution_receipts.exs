defmodule Sarah.Repo.Migrations.AllowAccountDeletionOfTurnExecutionReceipts do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION reject_shadow_program_run_mutation()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' AND
         NOT EXISTS (SELECT 1 FROM turn_receipts WHERE id = OLD.turn_receipt_id)
      THEN
        RETURN OLD;
      END IF;
      RAISE EXCEPTION 'terminal shadow-program receipts are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION reject_module_route_receipt_mutation()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' AND
         NOT EXISTS (SELECT 1 FROM turn_receipts WHERE id = OLD.turn_receipt_id)
      THEN
        RETURN OLD;
      END IF;
      RAISE EXCEPTION 'module route receipts are append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION reject_shadow_program_run_mutation()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'terminal shadow-program receipts are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION reject_module_route_receipt_mutation()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'module route receipts are append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)
  end
end
