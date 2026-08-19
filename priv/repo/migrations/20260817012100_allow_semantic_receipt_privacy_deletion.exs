defmodule Sarah.Repo.Migrations.AllowSemanticReceiptPrivacyDeletion do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION reject_semantic_receipt_mutation()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' AND NOT EXISTS (
        SELECT 1 FROM conversations WHERE id = OLD.conversation_id
      ) THEN
        RETURN OLD;
      END IF;

      RAISE EXCEPTION 'semantic derivative receipts are append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION reject_semantic_receipt_mutation()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'semantic derivative receipts are append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)
  end
end
