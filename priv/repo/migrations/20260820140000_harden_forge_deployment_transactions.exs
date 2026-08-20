defmodule OpenAgents.Repo.Migrations.HardenForgeDeploymentTransactions do
  use Ecto.Migration

  def up do
    alter table(:forge_deploys) do
      add :deployment_id, :uuid
      add :artifact_digest, :string
      add :manifest_digest, :string
      add :expected_nodes, {:array, :string}, null: false, default: []
      add :node_results, :map, null: false, default: %{}
      add :error_code, :string
      add :rollback_verified, :boolean
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
    end

    execute("""
    UPDATE forge_deploys
       SET deployment_id = gen_random_uuid(),
           expected_nodes = COALESCE(nodes, ARRAY[]::varchar[]),
           node_results = '{}'::jsonb,
           started_at = inserted_at,
           completed_at = inserted_at
    """)

    alter table(:forge_deploys) do
      modify :deployment_id, :uuid, null: false
      modify :started_at, :utc_datetime_usec, null: false
      modify :completed_at, :utc_datetime_usec, null: false
    end

    create unique_index(:forge_deploys, [:deployment_id])
    create index(:forge_deploys, [:target_id, :completed_at])

    create constraint(:forge_deploys, :forge_deploys_artifact_digest,
             check: "artifact_digest IS NULL OR artifact_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:forge_deploys, :forge_deploys_manifest_digest,
             check: "manifest_digest IS NULL OR manifest_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:forge_deploys, :forge_deploys_node_bounds,
             check:
               "cardinality(nodes) <= 100 AND cardinality(expected_nodes) <= 100 AND jsonb_typeof(node_results) = 'object' AND octet_length(node_results::text) <= 32768"
           )

    execute("""
    CREATE FUNCTION reject_forge_deploy_receipt_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      RAISE EXCEPTION 'forge deployment receipts are immutable';
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER forge_deploy_receipts_immutable
    BEFORE UPDATE OR DELETE ON forge_deploys
    FOR EACH ROW EXECUTE FUNCTION reject_forge_deploy_receipt_mutation()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS forge_deploy_receipts_immutable ON forge_deploys")
    execute("DROP FUNCTION IF EXISTS reject_forge_deploy_receipt_mutation()")

    drop constraint(:forge_deploys, :forge_deploys_node_bounds)
    drop constraint(:forge_deploys, :forge_deploys_manifest_digest)
    drop constraint(:forge_deploys, :forge_deploys_artifact_digest)
    drop index(:forge_deploys, [:target_id, :completed_at])
    drop index(:forge_deploys, [:deployment_id])

    alter table(:forge_deploys) do
      remove :deployment_id
      remove :artifact_digest
      remove :manifest_digest
      remove :expected_nodes
      remove :node_results
      remove :error_code
      remove :rollback_verified
      remove :started_at
      remove :completed_at
    end
  end
end
