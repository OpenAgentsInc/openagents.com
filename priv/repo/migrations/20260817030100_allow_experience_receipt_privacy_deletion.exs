defmodule Sarah.Repo.Migrations.AllowExperienceReceiptPrivacyDeletion do
  use Ecto.Migration

  def up do
    replace_bank_turn_foreign_key("CASCADE")

    execute("""
    CREATE OR REPLACE FUNCTION reject_experience_deletion_receipt_mutation()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' AND NOT EXISTS (
        SELECT 1 FROM visitors WHERE id = OLD.owner_visitor_id
      ) THEN
        RETURN OLD;
      END IF;
      RAISE EXCEPTION 'experience deletion receipts are append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  def down do
    replace_bank_turn_foreign_key("RESTRICT")

    execute("""
    CREATE OR REPLACE FUNCTION reject_experience_deletion_receipt_mutation()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'experience deletion receipts are append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  defp replace_bank_turn_foreign_key(on_delete) do
    execute("ALTER TABLE experience_banks DROP CONSTRAINT experience_banks_turn_id_fkey")

    execute("""
    ALTER TABLE experience_banks
    ADD CONSTRAINT experience_banks_turn_id_fkey
    FOREIGN KEY (turn_id) REFERENCES turns(id) ON DELETE #{on_delete}
    """)
  end
end
