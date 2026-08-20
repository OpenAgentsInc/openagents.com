defmodule OpenAgents.Repo.Migrations.ReconcileVisitorIdentityConstraint do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conname = 'visitors_identity_source_check'
           AND conrelid = 'visitors'::regclass
      ) THEN
        ALTER TABLE visitors
          ADD CONSTRAINT visitors_identity_source_check
          CHECK (
            (browser_key_hash IS NOT NULL AND user_id IS NULL) OR
            (browser_key_hash IS NULL AND user_id IS NOT NULL)
          );
      END IF;
    END
    $$;
    """)
  end

  def down do
    # The prior database lineage already owns this constraint. A down migration
    # cannot distinguish that inherited constraint from one created above, so
    # preserving it is the only rollback-compatible operation.
    :ok
  end
end
