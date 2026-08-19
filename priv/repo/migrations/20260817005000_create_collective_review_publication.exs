defmodule Sarah.Repo.Migrations.CreateCollectiveReviewPublication do
  use Ecto.Migration

  def up do
    alter table(:collective_generalization_receipts) do
      add :reviewer_actor_id, :string, null: false, default: "unrecorded:v1"
      add :reviewer_auth_method, :string, null: false, default: "unrecorded:v1"
    end

    alter table(:collective_generalization_receipts) do
      modify :reviewer_actor_id, :string, default: nil
      modify :reviewer_auth_method, :string, default: nil
    end

    drop constraint(:collective_candidates, :collective_candidate_state_check)

    create constraint(:collective_candidates, :collective_candidate_state_check,
             check:
               "status IN ('consented','generalized','rejected','review_rejected','reviewed','operator_rejected','published','revoked','withdrawn','revocation_pending')"
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

      IF OLD.status <> 'consented' AND OLD.generalized_payload IS DISTINCT FROM NEW.generalized_payload THEN
        RAISE EXCEPTION 'collective generalized payload is immutable';
      END IF;

      IF OLD.evaluator_ref IS DISTINCT FROM NEW.evaluator_ref AND
        NOT (
          (OLD.status = 'consented' AND NEW.status = 'generalized') OR
          (OLD.status = 'generalized' AND NEW.status IN ('reviewed','review_rejected'))
        ) THEN
        RAISE EXCEPTION 'collective evaluator reference transition is invalid';
      END IF;

      IF cardinality(NEW.review_refs) < cardinality(OLD.review_refs) OR
        cardinality(NEW.publication_refs) < cardinality(OLD.publication_refs) THEN
        RAISE EXCEPTION 'collective receipt references are append-only';
      END IF;

      IF OLD.status IN ('withdrawn','revoked') AND OLD.status IS DISTINCT FROM NEW.status THEN
        RAISE EXCEPTION 'retired collective candidate is terminal';
      END IF;

      IF OLD.status = 'consented' AND NEW.status NOT IN ('consented','generalized','rejected','withdrawn','revocation_pending') THEN
        RAISE EXCEPTION 'invalid collective consent transition';
      ELSIF OLD.status = 'generalized' AND NEW.status NOT IN ('generalized','reviewed','review_rejected','withdrawn') THEN
        RAISE EXCEPTION 'invalid collective review transition';
      ELSIF OLD.status = 'reviewed' AND NEW.status NOT IN ('reviewed','operator_rejected','published','withdrawn') THEN
        RAISE EXCEPTION 'invalid collective publication transition';
      ELSIF OLD.status = 'operator_rejected' AND NEW.status NOT IN ('operator_rejected','withdrawn') THEN
        RAISE EXCEPTION 'invalid collective operator rejection transition';
      ELSIF OLD.status = 'published' AND NEW.status NOT IN ('published','revocation_pending','revoked') THEN
        RAISE EXCEPTION 'invalid collective published transition';
      ELSIF OLD.status = 'revocation_pending' AND NEW.status NOT IN ('revocation_pending','revoked') THEN
        RAISE EXCEPTION 'invalid collective revocation transition';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    create table(:collective_review_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :candidate_id,
          references(:collective_candidates, type: :binary_id, on_delete: :restrict),
          null: false

      add :generalization_receipt_id,
          references(:collective_generalization_receipts, type: :binary_id, on_delete: :restrict),
          null: false

      add :decision, :string, null: false
      add :reason_codes, {:array, :string}, null: false, default: []
      add :evaluator_artifact_ref, :string, null: false
      add :evaluator_artifact_digest, :string, null: false
      add :dataset_ref, :string, null: false
      add :dataset_digest, :string, null: false
      add :policy_id, :string, null: false
      add :policy_version, :integer, null: false
      add :policy_digest, :string, null: false
      add :candidate_digest, :string, null: false
      add :evaluation_digest, :string, null: false
      add :dimensions, :map, null: false
      add :reviewer_actor_id, :string, null: false
      add :reviewer_auth_method, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:collective_review_receipts, [:candidate_id])
    create unique_index(:collective_review_receipts, [:evaluation_digest])

    create constraint(:collective_review_receipts, :collective_review_receipt_digest_check,
             check:
               "evaluator_artifact_digest ~ '^[0-9a-f]{64}$' AND dataset_digest ~ '^[0-9a-f]{64}$' AND policy_digest ~ '^[0-9a-f]{64}$' AND candidate_digest ~ '^[0-9a-f]{64}$' AND evaluation_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:collective_review_receipts, :collective_review_receipt_decision_check,
             check:
               "(decision = 'passed' AND cardinality(reason_codes) = 0) OR (decision = 'rejected' AND cardinality(reason_codes) > 0)"
           )

    create table(:collective_operator_decision_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :candidate_id,
          references(:collective_candidates, type: :binary_id, on_delete: :restrict),
          null: false

      add :review_receipt_id,
          references(:collective_review_receipts, type: :binary_id, on_delete: :restrict),
          null: false

      add :decision, :string, null: false
      add :candidate_digest, :string, null: false
      add :review_digest, :string, null: false
      add :operator_actor_id, :string, null: false
      add :operator_auth_method, :string, null: false
      add :approval_receipt_ref, :string, null: false
      add :reason, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:collective_operator_decision_receipts, [:candidate_id])
    create unique_index(:collective_operator_decision_receipts, [:approval_receipt_ref])

    create constraint(
             :collective_operator_decision_receipts,
             :collective_operator_decision_digest_check,
             check: "candidate_digest ~ '^[0-9a-f]{64}$' AND review_digest ~ '^[0-9a-f]{64}$'"
           )

    create table(:collective_publication_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :candidate_id,
          references(:collective_candidates, type: :binary_id, on_delete: :restrict),
          null: false

      add :review_receipt_id,
          references(:collective_review_receipts, type: :binary_id, on_delete: :restrict),
          null: false

      add :generation, :integer, null: false
      add :action, :string, null: false
      add :state, :string, null: false
      add :module_id, :string, null: false
      add :module_version, :integer, null: false
      add :artifact, :map, null: false
      add :artifact_digest, :string, null: false
      add :predecessor, :map
      add :attribution_lineage, {:array, :string}, null: false, default: []
      add :operator_actor_id, :string, null: false
      add :operator_auth_method, :string, null: false
      add :approval_receipt_ref, :string, null: false
      add :reason, :text, null: false
      add :derived_data_plan, :map, null: false
      add :plan_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:collective_publication_receipts, [:candidate_id, :generation])
    create unique_index(:collective_publication_receipts, [:approval_receipt_ref])

    create unique_index(:collective_publication_receipts, [:module_id, :module_version],
             where: "action = 'publish'",
             name: :collective_publication_unique_artifact
           )

    create index(:collective_publication_receipts, [:module_id, :module_version, :generation])

    create constraint(
             :collective_publication_receipts,
             :collective_publication_receipt_digest_check,
             check: "artifact_digest ~ '^[0-9a-f]{64}$' AND plan_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:collective_publication_receipts, :collective_publication_state_check,
             check:
               "(action = 'publish' AND generation = 1 AND state = 'staged') OR (action IN ('revoke','rollback') AND generation > 1 AND state = 'revoked')"
           )

    append_only(:collective_review_receipts, "reject_collective_review_receipt_mutation")

    append_only(
      :collective_operator_decision_receipts,
      "reject_collective_operator_decision_receipt_mutation"
    )

    append_only(
      :collective_publication_receipts,
      "reject_collective_publication_receipt_mutation"
    )
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS collective_publication_receipts_append_only ON collective_publication_receipts"
    )

    execute("DROP FUNCTION IF EXISTS reject_collective_publication_receipt_mutation()")

    execute(
      "DROP TRIGGER IF EXISTS collective_review_receipts_append_only ON collective_review_receipts"
    )

    execute("DROP FUNCTION IF EXISTS reject_collective_review_receipt_mutation()")

    execute(
      "DROP TRIGGER IF EXISTS collective_operator_decision_receipts_append_only ON collective_operator_decision_receipts"
    )

    execute("DROP FUNCTION IF EXISTS reject_collective_operator_decision_receipt_mutation()")
    drop table(:collective_publication_receipts)
    drop_if_exists table(:collective_operator_decision_receipts)
    drop table(:collective_review_receipts)

    alter table(:collective_generalization_receipts) do
      remove :reviewer_actor_id
      remove :reviewer_auth_method
    end
  end

  defp append_only(table, function) do
    execute("""
    CREATE FUNCTION #{function}()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION '#{table} rows are append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER #{table}_append_only
    BEFORE UPDATE OR DELETE ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{function}();
    """)
  end
end
