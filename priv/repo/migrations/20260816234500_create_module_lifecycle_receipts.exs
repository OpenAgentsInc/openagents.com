defmodule Sarah.Repo.Migrations.CreateModuleLifecycleReceipts do
  use Ecto.Migration

  def up do
    create table(:module_lifecycle_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :module_id, :string, null: false
      add :module_version, :integer, null: false
      add :generation, :integer, null: false
      add :action, :string, null: false
      add :from_state, :string, null: false
      add :to_state, :string, null: false
      add :base_artifact_digest, :string, null: false
      add :resulting_artifact_digest, :string, null: false
      add :base_registry_digest, :string, null: false
      add :resulting_registry_digest, :string, null: false
      add :actor_id, :string, null: false
      add :auth_method, :string, null: false
      add :approval_receipt_ref, :string, null: false
      add :reason, :text, null: false
      add :predecessor, :map
      add :deprecation, :map
      add :dependent_refs, {:array, :string}, null: false, default: []
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:module_lifecycle_receipts, [
             :module_id,
             :module_version,
             :generation
           ])

    create unique_index(:module_lifecycle_receipts, [:approval_receipt_ref])

    create constraint(:module_lifecycle_receipts, :module_lifecycle_state_check,
             check:
               "action IN ('stage','admit','deprecate','disable','revoke','rollback') AND from_state IN ('staged','admitted','deprecated','disabled','revoked') AND to_state IN ('staged','admitted','deprecated','disabled','revoked')"
           )

    create constraint(:module_lifecycle_receipts, :module_lifecycle_digest_check,
             check:
               "base_artifact_digest ~ '^[0-9a-f]{64}$' AND resulting_artifact_digest ~ '^[0-9a-f]{64}$' AND base_registry_digest ~ '^[0-9a-f]{64}$' AND resulting_registry_digest ~ '^[0-9a-f]{64}$'"
           )

    execute("""
    CREATE FUNCTION reject_module_lifecycle_receipt_mutation()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'module lifecycle receipts are append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER module_lifecycle_receipts_append_only
    BEFORE UPDATE OR DELETE ON module_lifecycle_receipts
    FOR EACH ROW EXECUTE FUNCTION reject_module_lifecycle_receipt_mutation();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS module_lifecycle_receipts_append_only ON module_lifecycle_receipts"
    )

    execute("DROP FUNCTION IF EXISTS reject_module_lifecycle_receipt_mutation()")
    drop table(:module_lifecycle_receipts)
  end
end
