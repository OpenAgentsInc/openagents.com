defmodule Sarah.Repo.Migrations.CreatePrivateExperienceMemory do
  use Ecto.Migration

  def up do
    create table(:experience_scopes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id, references(:visitors, type: :binary_id, on_delete: :delete_all),
        null: false

      add :work_scope, :string, null: false
      add :generation, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:experience_scopes, [:owner_visitor_id, :work_scope])

    create table(:experience_records, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id, references(:visitors, type: :binary_id, on_delete: :delete_all),
        null: false

      add :scope_id, references(:experience_scopes, type: :binary_id, on_delete: :delete_all),
        null: false

      # Kept as an opaque historical reference so deleting a corrected source does
      # not mutate or delete its independently governed replacement record.
      add :supersedes_record_id, :binary_id

      add :work_scope, :string, null: false
      add :objective, :text, null: false
      add :approach, :text, null: false
      add :outcome_state, :string, null: false
      add :outcome, :text
      add :correction, :text
      add :applicability, :text, null: false
      add :confidence_millis, :integer, null: false
      add :retention_until, :utc_datetime_usec
      add :policy_id, :string, null: false
      add :policy_version, :integer, null: false
      add :content_digest, :string, null: false
      add :generation, :bigint, null: false, default: 1
      add :scope_generation, :bigint, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:experience_records, [:owner_visitor_id, :work_scope, :outcome_state, :id],
             name: :experience_scope_state_index
           )

    create index(:experience_records, [:supersedes_record_id])

    create table(:experience_evidence_refs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :record_id, references(:experience_records, type: :binary_id, on_delete: :delete_all),
        null: false

      add :owner_visitor_id, :binary_id, null: false
      add :work_scope, :string, null: false
      add :kind, :string, null: false
      add :reference, :string, null: false
      add :reference_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:experience_evidence_refs, [:record_id, :kind, :reference],
             name: :experience_evidence_identity
           )

    create table(:experience_patterns, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id, references(:visitors, type: :binary_id, on_delete: :delete_all),
        null: false

      add :scope_id, references(:experience_scopes, type: :binary_id, on_delete: :delete_all),
        null: false

      add :work_scope, :string, null: false
      add :phenomenon, :text, null: false
      add :applicability, :text, null: false
      add :expected_effect, :text, null: false
      add :confidence_millis, :integer, null: false
      add :status, :string, null: false
      add :digest, :string, null: false
      add :generation, :bigint, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:experience_pattern_supports, primary_key: false) do
      add :pattern_id, references(:experience_patterns, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :record_id, references(:experience_records, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :outcome_state, :string, null: false
    end

    create table(:experience_banks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :turn_id, references(:turns, type: :binary_id, on_delete: :restrict), null: false

      add :owner_visitor_id, references(:visitors, type: :binary_id, on_delete: :delete_all),
        null: false

      add :scope_id, references(:experience_scopes, type: :binary_id, on_delete: :delete_all),
        null: false

      add :work_scope, :string, null: false
      add :scope_generation, :bigint, null: false
      add :query_digest, :string, null: false
      add :bank_digest, :string, null: false
      add :status, :string, null: false
      add :selected_record_refs, {:array, :string}, null: false, default: []
      add :selected_pattern_refs, {:array, :string}, null: false, default: []
      add :dropped_refs, {:array, :string}, null: false, default: []
      add :used_bytes, :integer, null: false
      add :frozen_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:experience_banks, [:turn_id])

    create table(:experience_bank_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :bank_id, references(:experience_banks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :record_id, references(:experience_records, type: :binary_id, on_delete: :delete_all)
      add :pattern_id, references(:experience_patterns, type: :binary_id, on_delete: :delete_all)
      add :kind, :string, null: false
      add :ordinal, :integer, null: false
      add :projection, :map, null: false
      add :projection_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:experience_bank_items, [:bank_id, :ordinal])

    create table(:experience_deletion_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_visitor_id, :binary_id, null: false
      add :work_scope, :string, null: false
      add :record_ref, :string, null: false
      add :source_ref_count, :integer, null: false
      add :bank_item_count, :integer, null: false
      add :pattern_count, :integer, null: false
      add :reason_code, :string, null: false
      add :receipt_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:experience_records, :experience_record_shape,
             check:
               "outcome_state IN ('requested','running','succeeded','failed','corrected') AND octet_length(objective) BETWEEN 1 AND 1000 AND octet_length(approach) BETWEEN 1 AND 1000 AND octet_length(applicability) BETWEEN 1 AND 1000 AND (outcome IS NULL OR octet_length(outcome) BETWEEN 1 AND 1000) AND (correction IS NULL OR octet_length(correction) BETWEEN 1 AND 1000) AND confidence_millis BETWEEN 0 AND 1000 AND policy_version > 0 AND content_digest ~ '^[0-9a-f]{64}$' AND generation > 0 AND scope_generation > 0"
           )

    create constraint(:experience_evidence_refs, :experience_evidence_shape,
             check:
               "kind IN ('source','trace','target','correction') AND octet_length(reference) BETWEEN 1 AND 256 AND reference_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:experience_patterns, :experience_pattern_shape,
             check:
               "status IN ('active','deleted') AND octet_length(phenomenon) BETWEEN 1 AND 1000 AND octet_length(applicability) BETWEEN 1 AND 1000 AND octet_length(expected_effect) BETWEEN 1 AND 1000 AND confidence_millis BETWEEN 0 AND 1000 AND digest ~ '^[0-9a-f]{64}$' AND generation > 0"
           )

    create constraint(:experience_pattern_supports, :experience_pattern_support_shape,
             check: "outcome_state IN ('succeeded','failed')"
           )

    create constraint(:experience_banks, :experience_bank_shape,
             check:
               "status IN ('frozen','invalidated') AND scope_generation >= 0 AND query_digest ~ '^[0-9a-f]{64}$' AND bank_digest ~ '^[0-9a-f]{64}$' AND used_bytes BETWEEN 0 AND 4000"
           )

    create constraint(:experience_bank_items, :experience_bank_item_shape,
             check:
               "kind IN ('record','pattern') AND ordinal BETWEEN 1 AND 16 AND ((kind='record' AND record_id IS NOT NULL AND pattern_id IS NULL) OR (kind='pattern' AND pattern_id IS NOT NULL AND record_id IS NULL)) AND projection_digest ~ '^[0-9a-f]{64}$' AND octet_length(projection::text) <= 4000"
           )

    create constraint(:experience_deletion_receipts, :experience_deletion_shape,
             check:
               "source_ref_count >= 0 AND bank_item_count >= 0 AND pattern_count >= 0 AND receipt_digest ~ '^[0-9a-f]{64}$'"
           )

    execute("""
    CREATE FUNCTION validate_successful_experience() RETURNS trigger AS $$
    BEGIN
      IF NEW.outcome_state='succeeded' AND NOT EXISTS (
        SELECT 1 FROM experience_evidence_refs r
        JOIN turn_tool_steps s ON r.reference = ANY(s.target_receipt_refs)
        JOIN turns t ON t.id=s.turn_id
        JOIN conversations c ON c.id=t.conversation_id
        WHERE r.record_id=NEW.id AND r.kind='target' AND s.status='succeeded'
          AND c.visitor_id=NEW.owner_visitor_id AND NEW.work_scope='conversation:' || c.id::text
      ) THEN RAISE EXCEPTION 'successful experience requires a scoped target receipt'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER successful_experience_receipt BEFORE INSERT OR UPDATE ON experience_records FOR EACH ROW EXECUTE FUNCTION validate_successful_experience()"
    )

    execute("""
    CREATE FUNCTION validate_experience_scope_membership() RETURNS trigger AS $$
    DECLARE scope_owner uuid; scope_work text;
    BEGIN
      SELECT owner_visitor_id,work_scope INTO scope_owner,scope_work
      FROM experience_scopes WHERE id=NEW.scope_id;
      IF scope_owner IS NULL OR scope_owner<>NEW.owner_visitor_id OR scope_work<>NEW.work_scope
      THEN RAISE EXCEPTION 'experience scope membership mismatch'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    for table <- ["experience_records", "experience_patterns"] do
      execute(
        "CREATE TRIGGER #{table}_scope BEFORE INSERT ON #{table} FOR EACH ROW EXECUTE FUNCTION validate_experience_scope_membership()"
      )
    end

    execute("""
    CREATE FUNCTION validate_experience_bank_scope() RETURNS trigger AS $$
    DECLARE scope_owner uuid; scope_work text; turn_owner uuid; turn_work text;
    BEGIN
      SELECT owner_visitor_id,work_scope INTO scope_owner,scope_work
      FROM experience_scopes WHERE id=NEW.scope_id;
      SELECT c.visitor_id,'conversation:' || c.id::text INTO turn_owner,turn_work
      FROM turns t JOIN conversations c ON c.id=t.conversation_id WHERE t.id=NEW.turn_id;
      IF scope_owner IS NULL OR scope_owner<>NEW.owner_visitor_id OR scope_work<>NEW.work_scope OR
         turn_owner IS NULL OR turn_owner<>NEW.owner_visitor_id OR turn_work<>NEW.work_scope
      THEN RAISE EXCEPTION 'experience bank turn scope mismatch'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER experience_banks_scope BEFORE INSERT ON experience_banks FOR EACH ROW EXECUTE FUNCTION validate_experience_bank_scope()"
    )

    execute("""
    CREATE FUNCTION validate_experience_evidence_scope() RETURNS trigger AS $$
    DECLARE record_owner uuid; record_work text; record_state text;
    BEGIN
      SELECT owner_visitor_id,work_scope,outcome_state INTO record_owner,record_work,record_state
      FROM experience_records WHERE id=NEW.record_id;
      IF record_owner IS NULL OR record_owner<>NEW.owner_visitor_id OR record_work<>NEW.work_scope
      THEN RAISE EXCEPTION 'experience evidence scope mismatch'; END IF;
      IF NEW.kind='target' AND record_state<>'running'
      THEN RAISE EXCEPTION 'target evidence requires running case'; END IF;
      IF NEW.kind='correction' AND record_state<>'corrected'
      THEN RAISE EXCEPTION 'correction evidence requires corrected case'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER experience_evidence_scope BEFORE INSERT ON experience_evidence_refs FOR EACH ROW EXECUTE FUNCTION validate_experience_evidence_scope()"
    )

    execute("""
    CREATE FUNCTION validate_experience_pattern_support_scope() RETURNS trigger AS $$
    DECLARE pattern_owner uuid; pattern_work text; record_owner uuid; record_work text; record_state text;
    BEGIN
      SELECT owner_visitor_id,work_scope INTO pattern_owner,pattern_work
      FROM experience_patterns WHERE id=NEW.pattern_id;
      SELECT owner_visitor_id,work_scope,outcome_state INTO record_owner,record_work,record_state
      FROM experience_records WHERE id=NEW.record_id;
      IF pattern_owner IS NULL OR record_owner IS NULL OR pattern_owner<>record_owner OR
         pattern_work<>record_work OR record_state NOT IN ('succeeded','failed') OR
         NEW.outcome_state<>record_state
      THEN RAISE EXCEPTION 'experience pattern support mismatch'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER experience_pattern_support_scope BEFORE INSERT ON experience_pattern_supports FOR EACH ROW EXECUTE FUNCTION validate_experience_pattern_support_scope()"
    )

    execute("""
    CREATE FUNCTION validate_experience_bank_item_scope() RETURNS trigger AS $$
    DECLARE bank_owner uuid; bank_work text; item_owner uuid; item_work text;
    BEGIN
      SELECT owner_visitor_id,work_scope INTO bank_owner,bank_work
      FROM experience_banks WHERE id=NEW.bank_id;
      IF NEW.kind='record' THEN
        SELECT owner_visitor_id,work_scope INTO item_owner,item_work
        FROM experience_records WHERE id=NEW.record_id;
      ELSE
        SELECT owner_visitor_id,work_scope INTO item_owner,item_work
        FROM experience_patterns WHERE id=NEW.pattern_id;
      END IF;
      IF bank_owner IS NULL OR item_owner IS NULL OR bank_owner<>item_owner OR bank_work<>item_work
      THEN RAISE EXCEPTION 'experience bank item scope mismatch'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER experience_bank_item_scope BEFORE INSERT ON experience_bank_items FOR EACH ROW EXECUTE FUNCTION validate_experience_bank_item_scope()"
    )

    execute("""
    CREATE FUNCTION protect_experience_identity() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.owner_visitor_id,OLD.scope_id,OLD.work_scope,OLD.objective,OLD.approach,
        OLD.applicability,OLD.confidence_millis,OLD.retention_until,OLD.policy_id,
        OLD.policy_version,OLD.content_digest,OLD.supersedes_record_id) IS DISTINCT FROM
        ROW(NEW.owner_visitor_id,NEW.scope_id,NEW.work_scope,NEW.objective,NEW.approach,
        NEW.applicability,NEW.confidence_millis,NEW.retention_until,NEW.policy_id,
        NEW.policy_version,NEW.content_digest,NEW.supersedes_record_id)
      THEN RAISE EXCEPTION 'experience identity is immutable'; END IF;
      IF NEW.generation <> OLD.generation + 1 OR NEW.scope_generation <= OLD.scope_generation
      THEN RAISE EXCEPTION 'experience generation must advance'; END IF;
      IF NOT ((OLD.outcome_state='requested' AND NEW.outcome_state IN ('running','failed')) OR
              (OLD.outcome_state='running' AND NEW.outcome_state IN ('succeeded','failed')) OR
              (OLD.outcome_state IN ('succeeded','failed') AND NEW.outcome_state='corrected'))
      THEN RAISE EXCEPTION 'invalid experience transition'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER experience_transition_guard BEFORE UPDATE ON experience_records FOR EACH ROW EXECUTE FUNCTION protect_experience_identity()"
    )

    for table <- ["experience_evidence_refs", "experience_bank_items"] do
      execute(
        "CREATE FUNCTION reject_#{table}_update() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION '#{table} rows are immutable'; END; $$ LANGUAGE plpgsql;"
      )

      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION reject_#{table}_update()"
      )
    end

    execute("""
    CREATE FUNCTION protect_experience_bank() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.turn_id,OLD.owner_visitor_id,OLD.scope_id,OLD.work_scope,OLD.scope_generation,
        OLD.query_digest,OLD.bank_digest,OLD.selected_record_refs,OLD.selected_pattern_refs,
        OLD.dropped_refs,OLD.used_bytes,OLD.frozen_at,OLD.inserted_at) IS DISTINCT FROM
        ROW(NEW.turn_id,NEW.owner_visitor_id,NEW.scope_id,NEW.work_scope,NEW.scope_generation,
        NEW.query_digest,NEW.bank_digest,NEW.selected_record_refs,NEW.selected_pattern_refs,
        NEW.dropped_refs,NEW.used_bytes,NEW.frozen_at,NEW.inserted_at)
      THEN RAISE EXCEPTION 'experience bank identity is immutable'; END IF;
      IF NOT (OLD.status='frozen' AND NEW.status='invalidated')
      THEN RAISE EXCEPTION 'invalid experience bank transition'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER experience_bank_guard BEFORE UPDATE ON experience_banks FOR EACH ROW EXECUTE FUNCTION protect_experience_bank()"
    )

    execute(
      "CREATE FUNCTION reject_experience_deletion_receipt_mutation() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'experience deletion receipts are append-only'; END; $$ LANGUAGE plpgsql;"
    )

    execute(
      "CREATE TRIGGER experience_deletion_receipts_append_only BEFORE UPDATE OR DELETE ON experience_deletion_receipts FOR EACH ROW EXECUTE FUNCTION reject_experience_deletion_receipt_mutation()"
    )

    execute(
      "CREATE FUNCTION protect_turn_experience_capture() RETURNS trigger AS $$ BEGIN IF OLD.experience_bank_ref IS DISTINCT FROM NEW.experience_bank_ref OR OLD.used_experiences IS DISTINCT FROM NEW.used_experiences THEN RAISE EXCEPTION 'turn experience capture is immutable'; END IF; RETURN NEW; END; $$ LANGUAGE plpgsql;"
    )

    execute(
      "CREATE TRIGGER turn_experience_capture_immutable BEFORE UPDATE ON turn_receipts FOR EACH ROW EXECUTE FUNCTION protect_turn_experience_capture()"
    )
  end

  def down do
    execute("DROP FUNCTION IF EXISTS protect_turn_experience_capture() CASCADE")
    execute("DROP FUNCTION IF EXISTS reject_experience_deletion_receipt_mutation() CASCADE")
    execute("DROP FUNCTION IF EXISTS protect_experience_bank() CASCADE")
    execute("DROP FUNCTION IF EXISTS protect_experience_identity() CASCADE")
    execute("DROP FUNCTION IF EXISTS validate_experience_bank_item_scope() CASCADE")
    execute("DROP FUNCTION IF EXISTS validate_experience_pattern_support_scope() CASCADE")
    execute("DROP FUNCTION IF EXISTS validate_experience_evidence_scope() CASCADE")
    execute("DROP FUNCTION IF EXISTS validate_experience_bank_scope() CASCADE")
    execute("DROP FUNCTION IF EXISTS validate_experience_scope_membership() CASCADE")
    execute("DROP FUNCTION IF EXISTS validate_successful_experience() CASCADE")

    for table <- ["experience_evidence_refs", "experience_bank_items"],
        do: execute("DROP FUNCTION IF EXISTS reject_#{table}_update() CASCADE")

    drop table(:experience_deletion_receipts)
    drop table(:experience_bank_items)
    drop table(:experience_banks)
    drop table(:experience_pattern_supports)
    drop table(:experience_patterns)
    drop table(:experience_evidence_refs)
    drop table(:experience_records)
    drop table(:experience_scopes)
  end
end
