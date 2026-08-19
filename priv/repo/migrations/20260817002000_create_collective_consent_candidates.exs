defmodule Sarah.Repo.Migrations.CreateCollectiveConsentCandidates do
  use Ecto.Migration

  def up do
    create table(:collective_consent_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :visitor_id, references(:visitors, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_scope_ref, :string, null: false
      add :source_scope_digest, :string, null: false
      add :source_refs, {:array, :string}, null: false
      add :source_digest, :string, null: false
      add :category, :string, null: false
      add :intended_use, :string, null: false
      add :attribution_disclosure, :string, null: false
      add :compensation_disclosure, :string, null: false
      add :policy_id, :string, null: false
      add :policy_version, :integer, null: false
      add :policy_digest, :string, null: false
      add :confirmation_digest, :string, null: false
      add :status, :string, null: false, default: "active"
      add :granted_at, :utc_datetime_usec, null: false
      add :withdrawn_at, :utc_datetime_usec
      add :withdrawal_reason, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:collective_consent_receipts, [:confirmation_digest])
    create index(:collective_consent_receipts, [:visitor_id, :status])

    create constraint(:collective_consent_receipts, :collective_consent_digest_check,
             check:
               "source_scope_digest ~ '^[0-9a-f]{64}$' AND source_digest ~ '^[0-9a-f]{64}$' AND policy_digest ~ '^[0-9a-f]{64}$' AND confirmation_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:collective_consent_receipts, :collective_consent_state_check,
             check:
               "(status = 'active' AND withdrawn_at IS NULL AND withdrawal_reason IS NULL) OR (status = 'withdrawn' AND withdrawn_at IS NOT NULL AND withdrawal_reason IS NOT NULL)"
           )

    create table(:collective_candidates, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :visitor_id, references(:visitors, type: :binary_id, on_delete: :delete_all),
        null: false

      add :consent_receipt_id,
          references(:collective_consent_receipts, type: :binary_id, on_delete: :restrict),
          null: false

      add :source_scope_digest, :string, null: false
      add :provenance_refs, {:array, :string}, null: false
      add :redaction_policy_id, :string, null: false
      add :redaction_policy_version, :integer, null: false
      add :redaction_policy_digest, :string, null: false
      add :generalized_kind, :string, null: false
      add :generalized_payload, :map
      add :evaluator_ref, :string
      add :status, :string, null: false, default: "consented"
      add :review_refs, {:array, :string}, null: false, default: []
      add :publication_refs, {:array, :string}, null: false, default: []
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:collective_candidates, [:consent_receipt_id])
    create index(:collective_candidates, [:visitor_id, :status])

    create constraint(:collective_candidates, :collective_candidate_state_check,
             check: "status IN ('consented','withdrawn','revocation_pending')"
           )

    create constraint(:collective_candidates, :collective_candidate_digest_check,
             check:
               "source_scope_digest ~ '^[0-9a-f]{64}$' AND redaction_policy_digest ~ '^[0-9a-f]{64}$'"
           )

    execute("""
    CREATE FUNCTION enforce_collective_consent_transition()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        OLD.visitor_id, OLD.source_scope_ref, OLD.source_scope_digest,
        OLD.source_refs, OLD.source_digest, OLD.category, OLD.intended_use,
        OLD.attribution_disclosure, OLD.compensation_disclosure, OLD.policy_id,
        OLD.policy_version, OLD.policy_digest, OLD.confirmation_digest, OLD.granted_at
      ) IS DISTINCT FROM ROW(
        NEW.visitor_id, NEW.source_scope_ref, NEW.source_scope_digest,
        NEW.source_refs, NEW.source_digest, NEW.category, NEW.intended_use,
        NEW.attribution_disclosure, NEW.compensation_disclosure, NEW.policy_id,
        NEW.policy_version, NEW.policy_digest, NEW.confirmation_digest, NEW.granted_at
      ) THEN
        RAISE EXCEPTION 'collective consent identity is immutable';
      END IF;

      IF OLD.status = 'withdrawn' AND ROW(OLD.status, OLD.withdrawn_at, OLD.withdrawal_reason)
        IS DISTINCT FROM ROW(NEW.status, NEW.withdrawn_at, NEW.withdrawal_reason) THEN
        RAISE EXCEPTION 'withdrawn collective consent is immutable';
      END IF;

      IF OLD.status = 'active' AND NEW.status NOT IN ('active','withdrawn') THEN
        RAISE EXCEPTION 'invalid collective consent transition';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER collective_consent_enforce_transition
    BEFORE UPDATE ON collective_consent_receipts
    FOR EACH ROW EXECUTE FUNCTION enforce_collective_consent_transition();
    """)

    execute("""
    CREATE FUNCTION enforce_collective_candidate_transition()
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

      IF OLD.status IN ('withdrawn','revocation_pending') AND OLD.status IS DISTINCT FROM NEW.status THEN
        RAISE EXCEPTION 'withdrawn collective candidate is terminal';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER collective_candidate_enforce_transition
    BEFORE UPDATE ON collective_candidates
    FOR EACH ROW EXECUTE FUNCTION enforce_collective_candidate_transition();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS collective_candidate_enforce_transition ON collective_candidates"
    )

    execute("DROP FUNCTION IF EXISTS enforce_collective_candidate_transition()")

    execute(
      "DROP TRIGGER IF EXISTS collective_consent_enforce_transition ON collective_consent_receipts"
    )

    execute("DROP FUNCTION IF EXISTS enforce_collective_consent_transition()")
    drop table(:collective_candidates)
    drop table(:collective_consent_receipts)
  end
end
