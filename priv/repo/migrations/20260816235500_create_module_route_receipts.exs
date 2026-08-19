defmodule Sarah.Repo.Migrations.CreateModuleRouteReceipts do
  use Ecto.Migration

  def up do
    create table(:module_route_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :turn_receipt_id,
          references(:turn_receipts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :provider_call_id, :string, null: false
      add :status, :string, null: false
      add :reason, :string, null: false
      add :intent_digest, :string, null: false
      add :registry_digest, :string, null: false
      add :policy_id, :string, null: false
      add :policy_digest, :string, null: false
      add :required_capability, :string, null: false
      add :required_side_effect, :string, null: false
      add :selected, :map
      add :proposed, :map
      add :rejected, {:array, :map}, null: false, default: []
      add :program_artifact, :map
      add :fallback, :boolean, null: false, default: false
      add :degraded, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:module_route_receipts, [:turn_receipt_id, :provider_call_id])

    create constraint(:module_route_receipts, :module_route_receipt_status_check,
             check:
               "status IN ('selected','unavailable','refused') AND required_side_effect IN ('read_only','reversible_write','external_effect')"
           )

    create constraint(:module_route_receipts, :module_route_receipt_digest_check,
             check:
               "intent_digest ~ '^[0-9a-f]{64}$' AND registry_digest ~ '^[0-9a-f]{64}$' AND policy_digest ~ '^[0-9a-f]{64}$'"
           )

    execute("""
    CREATE FUNCTION reject_module_route_receipt_mutation()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'module route receipts are append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER module_route_receipts_append_only
    BEFORE UPDATE OR DELETE ON module_route_receipts
    FOR EACH ROW EXECUTE FUNCTION reject_module_route_receipt_mutation();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS module_route_receipts_append_only ON module_route_receipts")
    execute("DROP FUNCTION IF EXISTS reject_module_route_receipt_mutation()")
    drop table(:module_route_receipts)
  end
end
