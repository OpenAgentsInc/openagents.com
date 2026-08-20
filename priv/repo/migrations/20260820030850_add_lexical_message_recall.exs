defmodule OpenAgents.Repo.Migrations.AddLexicalMessageRecall do
  use Ecto.Migration

  def up do
    execute("DROP INDEX IF EXISTS messages_completed_recall_gin_index")
    execute("ALTER TABLE messages DROP COLUMN IF EXISTS search_vector")

    execute("""
    ALTER TABLE messages
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('simple', coalesce(content, ''))) STORED
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS messages_completed_recall_gin_index
    ON messages USING GIN (search_vector)
    WHERE status = 'complete' AND role IN ('user', 'assistant')
    """)

    execute(
      "ALTER TABLE turn_receipts DROP CONSTRAINT IF EXISTS turn_receipts_memory_snapshot_ref_check"
    )

    create constraint(:turn_receipts, :turn_receipts_memory_snapshot_ref_check,
             check:
               "memory_snapshot_ref IS NULL OR memory_snapshot_ref ~ '^message:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'"
           )
  end

  def down do
    execute(
      "ALTER TABLE turn_receipts DROP CONSTRAINT IF EXISTS turn_receipts_memory_snapshot_ref_check"
    )

    execute("DROP INDEX IF EXISTS messages_completed_recall_gin_index")
    execute("ALTER TABLE messages DROP COLUMN IF EXISTS search_vector")
  end
end
