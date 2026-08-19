defmodule Sarah.Repo.Migrations.CreateCollectiveGeneralizationReceipts do
  use Ecto.Migration

  def up do
    drop constraint(:collective_candidates, :collective_candidate_state_check)

    create constraint(:collective_candidates, :collective_candidate_state_check,
             check:
               "status IN ('consented','generalized','rejected','withdrawn','revocation_pending')"
           )

    execute("""
    CREATE OR REPLACE FUNCTION enforce_collective_candidate_transition()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        OLD.visitor_id, OLD.consent_receipt_id, OLD.source_scope_digest,
        OLD.provenance_refs, OLD.redaction_policy_id, OLD.redaction_policy_version,
        OLD.redaction_policy_digest, OLD.generalized_kind
      ) IS DISTINCT FROM ROW(
        NEW.visitor_id, NEW.consent_receipt_id, NEW.source_scope_digest,
        NEW.provenance_refs, NEW.redaction_policy_id, NEW.redaction_policy_version,
        NEW.redaction_policy_digest, NEW.generalized_kind
      ) THEN
        RAISE EXCEPTION 'collective candidate private identity is immutable';
      END IF;

      IF OLD.status <> 'consented' AND ROW(OLD.generalized_payload, OLD.evaluator_ref)
        IS DISTINCT FROM ROW(NEW.generalized_payload, NEW.evaluator_ref) THEN
        RAISE EXCEPTION 'collective generalized payload is immutable';
      END IF;

      IF OLD.status IN ('withdrawn','revocation_pending') AND OLD.status IS DISTINCT FROM NEW.status THEN
        RAISE EXCEPTION 'withdrawn collective candidate is terminal';
      END IF;

      IF OLD.status = 'consented' AND NEW.status NOT IN ('consented','generalized','rejected','withdrawn','revocation_pending') THEN
        RAISE EXCEPTION 'invalid collective candidate transition';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    create table(:collective_generalization_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :candidate_id,
          references(:collective_candidates, type: :binary_id, on_delete: :delete_all),
          null: false

      add :visitor_id, references(:visitors, type: :binary_id, on_delete: :delete_all),
        null: false

      add :candidate_digest, :string, null: false
      add :source_digest, :string, null: false
      add :policy_id, :string, null: false
      add :policy_version, :integer, null: false
      add :policy_digest, :string, null: false
      add :generalizer_id, :string, null: false
      add :generalizer_version, :integer, null: false
      add :generalizer_digest, :string, null: false
      add :status, :string, null: false
      add :reason_codes, {:array, :string}, null: false, default: []
      add :risk, :string, null: false
      add :utility, :string, null: false
      add :support_signal, :string
      add :source_count, :integer, null: false
      add :output_digest, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:collective_generalization_receipts, [:candidate_id])
    create index(:collective_generalization_receipts, [:visitor_id, :status])

    create constraint(
             :collective_generalization_receipts,
             :collective_generalization_receipt_shape_check,
             check:
               "(status = 'generalized' AND risk = 'low' AND utility = 'sufficient' AND support_signal IS NOT NULL AND output_digest ~ '^[0-9a-f]{64}$') OR (status = 'rejected' AND risk = 'high' AND utility = 'insufficient' AND support_signal IS NULL AND output_digest IS NULL)"
           )

    create constraint(
             :collective_generalization_receipts,
             :collective_generalization_receipt_digest_check,
             check:
               "candidate_digest ~ '^[0-9a-f]{64}$' AND source_digest ~ '^[0-9a-f]{64}$' AND policy_digest ~ '^[0-9a-f]{64}$' AND generalizer_digest ~ '^[0-9a-f]{64}$'"
           )

    execute("""
    CREATE FUNCTION reject_collective_generalization_receipt_mutation()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'collective generalization receipts are append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER collective_generalization_receipts_append_only
    BEFORE UPDATE OR DELETE ON collective_generalization_receipts
    FOR EACH ROW EXECUTE FUNCTION reject_collective_generalization_receipt_mutation();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS collective_generalization_receipts_append_only ON collective_generalization_receipts"
    )

    execute("DROP FUNCTION IF EXISTS reject_collective_generalization_receipt_mutation()")
    drop table(:collective_generalization_receipts)
    drop constraint(:collective_candidates, :collective_candidate_state_check)

    create constraint(:collective_candidates, :collective_candidate_state_check,
             check: "status IN ('consented','withdrawn','revocation_pending')"
           )
  end
end
