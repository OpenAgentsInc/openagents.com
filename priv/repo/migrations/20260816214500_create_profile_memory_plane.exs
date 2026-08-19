defmodule Sarah.Repo.Migrations.CreateProfileMemoryPlane do
  use Ecto.Migration

  def up do
    create table(:profile_memory_scopes, primary_key: false) do
      add :owner_visitor_id,
          references(:visitors, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :generation, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:profile_memory_scopes, :profile_memory_scopes_generation_check,
             check: "generation >= 0"
           )

    create table(:profile_memory_records, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id,
          references(:visitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :schema_version, :integer, null: false, default: 1
      add :category, :string, null: false
      add :claim, :text, null: false
      add :claim_fingerprint, :binary, null: false
      add :status, :string, null: false, default: "candidate"
      add :provenance, :map, null: false, default: %{}
      add :confidence, :decimal, precision: 5, scale: 4, null: false
      add :valid_from, :utc_datetime_usec
      add :valid_until, :utc_datetime_usec
      add :confirmed_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :owner_asserted_at, :utc_datetime_usec
      add :redaction_policy, :string, null: false
      add :creator, :string, null: false
      add :creator_artifact_id, :string
      add :creator_artifact_digest, :string
      add :generation, :bigint, null: false, default: 1
      add :created_generation, :bigint, null: false
      add :active_generation, :bigint
      add :terminal_generation, :bigint

      add :supersedes_record_id,
          references(:profile_memory_records, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:profile_memory_records, :profile_memory_records_schema_check,
             check: "schema_version = 1"
           )

    create constraint(:profile_memory_records, :profile_memory_records_category_check,
             check: "category IN ('name', 'role', 'project', 'preference', 'constraint', 'other')"
           )

    create constraint(:profile_memory_records, :profile_memory_records_claim_bound_check,
             check: "octet_length(claim) BETWEEN 1 AND 500"
           )

    create constraint(:profile_memory_records, :profile_memory_records_claim_normalized_check,
             check: "claim = btrim(regexp_replace(claim, '[[:space:]]+', ' ', 'g'))"
           )

    create constraint(:profile_memory_records, :profile_memory_records_fingerprint_check,
             check: "octet_length(claim_fingerprint) = 32"
           )

    create constraint(:profile_memory_records, :profile_memory_records_status_check,
             check: "status IN ('candidate', 'active', 'superseded', 'forgotten', 'expired')"
           )

    create constraint(:profile_memory_records, :profile_memory_records_provenance_check,
             check:
               "jsonb_typeof(provenance) = 'object' AND octet_length(provenance::text) <= 4096"
           )

    create constraint(:profile_memory_records, :profile_memory_records_confidence_check,
             check: "confidence >= 0 AND confidence <= 1"
           )

    create constraint(:profile_memory_records, :profile_memory_records_validity_check,
             check: "valid_until IS NULL OR valid_from IS NULL OR valid_until > valid_from"
           )

    create constraint(:profile_memory_records, :profile_memory_records_expiry_check,
             check: "expires_at IS NULL OR valid_from IS NULL OR expires_at > valid_from"
           )

    create constraint(:profile_memory_records, :profile_memory_records_redaction_policy_check,
             check: "octet_length(redaction_policy) BETWEEN 1 AND 100"
           )

    create constraint(:profile_memory_records, :profile_memory_records_creator_check,
             check: "creator IN ('user_explicit', 'model_proposal', 'admin_migration')"
           )

    create constraint(:profile_memory_records, :profile_memory_records_artifact_pair_check,
             check:
               "(creator_artifact_id IS NULL) = (creator_artifact_digest IS NULL) AND " <>
                 "(creator_artifact_digest IS NULL OR creator_artifact_digest ~ '^[0-9a-f]{64}$')"
           )

    create constraint(:profile_memory_records, :profile_memory_records_generation_check,
             check:
               "generation >= 1 AND created_generation >= 1 AND " <>
                 "(active_generation IS NULL OR active_generation >= created_generation) AND " <>
                 "(terminal_generation IS NULL OR terminal_generation >= created_generation) AND " <>
                 "(terminal_generation IS NULL OR active_generation IS NULL OR terminal_generation > active_generation)"
           )

    create constraint(:profile_memory_records, :profile_memory_records_state_generation_check,
             check:
               "(status = 'candidate' AND active_generation IS NULL AND terminal_generation IS NULL) OR " <>
                 "(status = 'active' AND active_generation IS NOT NULL AND terminal_generation IS NULL) OR " <>
                 "(status IN ('superseded', 'forgotten', 'expired') AND terminal_generation IS NOT NULL)"
           )

    create index(:profile_memory_records, [:owner_visitor_id, :status, :category, :id],
             name: :profile_memory_records_owner_status_index
           )

    create index(
             :profile_memory_records,
             [:owner_visitor_id, :active_generation, :terminal_generation],
             name: :profile_memory_records_snapshot_index
           )

    create index(:profile_memory_records, [:owner_visitor_id, :expires_at],
             where: "status = 'active' AND expires_at IS NOT NULL",
             name: :profile_memory_records_expiry_index
           )

    create unique_index(
             :profile_memory_records,
             [:owner_visitor_id, :category, :claim_fingerprint],
             where: "status = 'active'",
             name: :profile_memory_records_active_claim_index
           )

    create unique_index(:profile_memory_records, [:owner_visitor_id, :category],
             where: "status = 'active' AND category IN ('name', 'role')",
             name: :profile_memory_records_active_singleton_index
           )

    create table(:profile_memory_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id,
          references(:visitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :scope_generation, :bigint, null: false
      add :captured_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create constraint(:profile_memory_snapshots, :profile_memory_snapshots_generation_check,
             check: "scope_generation >= 0"
           )

    create index(:profile_memory_snapshots, [:owner_visitor_id, :inserted_at, :id])

    create table(:profile_memory_sources, primary_key: false) do
      add :memory_record_id,
          references(:profile_memory_records, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :message_id,
          references(:messages, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :source_kind, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create constraint(:profile_memory_sources, :profile_memory_sources_kind_check,
             check: "source_kind IN ('owner_statement', 'owner_confirmation')"
           )

    create index(:profile_memory_sources, [:message_id])

    execute("""
    CREATE FUNCTION protect_profile_memory_record_identity()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.owner_visitor_id IS DISTINCT FROM OLD.owner_visitor_id OR
         NEW.schema_version IS DISTINCT FROM OLD.schema_version OR
         NEW.category IS DISTINCT FROM OLD.category OR
         NEW.claim IS DISTINCT FROM OLD.claim OR
         NEW.claim_fingerprint IS DISTINCT FROM OLD.claim_fingerprint OR
         NEW.provenance IS DISTINCT FROM OLD.provenance OR
         NEW.creator IS DISTINCT FROM OLD.creator OR
         NEW.creator_artifact_id IS DISTINCT FROM OLD.creator_artifact_id OR
         NEW.creator_artifact_digest IS DISTINCT FROM OLD.creator_artifact_digest OR
         NEW.owner_asserted_at IS DISTINCT FROM OLD.owner_asserted_at OR
         NEW.created_generation IS DISTINCT FROM OLD.created_generation OR
         NEW.supersedes_record_id IS DISTINCT FROM OLD.supersedes_record_id THEN
        RAISE EXCEPTION 'profile memory identity is immutable; create a correction';
      END IF;

      IF NEW.generation <> OLD.generation + 1 THEN
        RAISE EXCEPTION 'profile memory generation must advance exactly once';
      END IF;

      IF NOT (
        (OLD.status = 'candidate' AND NEW.status IN ('active', 'forgotten', 'expired')) OR
        (OLD.status = 'active' AND NEW.status IN ('superseded', 'forgotten', 'expired'))
      ) THEN
        RAISE EXCEPTION 'invalid profile memory lifecycle transition';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER profile_memory_record_identity_trigger
    BEFORE UPDATE ON profile_memory_records
    FOR EACH ROW EXECUTE FUNCTION protect_profile_memory_record_identity();
    """)

    execute("""
    CREATE FUNCTION validate_profile_memory_source_scope()
    RETURNS trigger AS $$
    DECLARE
      record_owner uuid;
      message_owner uuid;
      message_role text;
      message_status text;
    BEGIN
      SELECT owner_visitor_id INTO record_owner
      FROM profile_memory_records
      WHERE id = NEW.memory_record_id;

      SELECT c.visitor_id, m.role, m.status
      INTO message_owner, message_role, message_status
      FROM messages m
      JOIN conversations c ON c.id = m.conversation_id
      WHERE m.id = NEW.message_id;

      IF record_owner IS NULL OR message_owner IS NULL OR record_owner <> message_owner OR
         message_role <> 'user' OR message_status <> 'complete' THEN
        RAISE EXCEPTION 'invalid profile memory source';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER profile_memory_source_scope_trigger
    BEFORE INSERT OR UPDATE ON profile_memory_sources
    FOR EACH ROW EXECUTE FUNCTION validate_profile_memory_source_scope();
    """)

    execute("""
    CREATE FUNCTION validate_active_profile_memory_support(record_id uuid)
    RETURNS void AS $$
    DECLARE
      memory_status text;
      memory_owner uuid;
      memory_category text;
      memory_created_generation bigint;
      memory_active_generation bigint;
      memory_terminal_generation bigint;
      owner_scope_generation bigint;
      asserted_at timestamptz;
      has_valid_source boolean;
      owner_record_count integer;
      active_category_count integer;
      active_category_limit integer;
    BEGIN
      SELECT status, owner_visitor_id, category, owner_asserted_at,
             created_generation, active_generation, terminal_generation
      INTO memory_status, memory_owner, memory_category, asserted_at,
           memory_created_generation, memory_active_generation, memory_terminal_generation
      FROM profile_memory_records
      WHERE id = record_id;

      IF memory_status IS NULL THEN
        RETURN;
      END IF;

      SELECT generation INTO owner_scope_generation
      FROM profile_memory_scopes
      WHERE owner_visitor_id = memory_owner;

      IF owner_scope_generation IS NULL OR memory_created_generation > owner_scope_generation OR
         (memory_active_generation IS NOT NULL AND memory_active_generation > owner_scope_generation) OR
         (memory_terminal_generation IS NOT NULL AND memory_terminal_generation > owner_scope_generation) THEN
        RAISE EXCEPTION 'profile memory generation exceeds owner scope';
      END IF;

      SELECT count(*) INTO owner_record_count
      FROM profile_memory_records
      WHERE owner_visitor_id = memory_owner;

      IF owner_record_count > 200 THEN
        RAISE EXCEPTION 'profile memory owner record limit exceeded';
      END IF;

      IF memory_status <> 'active' THEN
        RETURN;
      END IF;

      IF asserted_at IS NULL THEN
        SELECT EXISTS(
          SELECT 1
          FROM profile_memory_sources s
          JOIN messages m ON m.id = s.message_id
          JOIN conversations c ON c.id = m.conversation_id
          WHERE s.memory_record_id = record_id
            AND c.visitor_id = memory_owner
            AND m.role = 'user'
            AND m.status = 'complete'
        ) INTO has_valid_source;

        IF NOT has_valid_source THEN
          RAISE EXCEPTION 'active profile memory requires owner assertion or valid source';
        END IF;
      END IF;

      active_category_limit := CASE memory_category
        WHEN 'name' THEN 1
        WHEN 'role' THEN 1
        WHEN 'project' THEN 25
        WHEN 'preference' THEN 50
        WHEN 'constraint' THEN 25
        WHEN 'other' THEN 25
      END;

      SELECT count(*) INTO active_category_count
      FROM profile_memory_records
      WHERE owner_visitor_id = memory_owner
        AND category = memory_category
        AND status = 'active';

      IF active_category_count > active_category_limit THEN
        RAISE EXCEPTION 'profile memory active category limit exceeded';
      END IF;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE FUNCTION validate_profile_memory_record_support_trigger()
    RETURNS trigger AS $$
    BEGIN
      PERFORM validate_active_profile_memory_support(COALESCE(NEW.id, OLD.id));
      RETURN COALESCE(NEW, OLD);
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER profile_memory_record_support_trigger
    AFTER INSERT OR UPDATE ON profile_memory_records
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION validate_profile_memory_record_support_trigger();
    """)

    execute("""
    CREATE FUNCTION validate_profile_memory_source_delete_trigger()
    RETURNS trigger AS $$
    BEGIN
      PERFORM validate_active_profile_memory_support(OLD.memory_record_id);
      RETURN OLD;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER profile_memory_source_delete_support_trigger
    AFTER DELETE ON profile_memory_sources
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION validate_profile_memory_source_delete_trigger();
    """)

    execute("""
    CREATE FUNCTION validate_profile_memory_snapshot()
    RETURNS trigger AS $$
    DECLARE
      current_generation bigint;
    BEGIN
      SELECT generation INTO current_generation
      FROM profile_memory_scopes
      WHERE owner_visitor_id = NEW.owner_visitor_id;

      IF current_generation IS NULL OR NEW.scope_generation <> current_generation THEN
        RAISE EXCEPTION 'invalid profile memory snapshot generation';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER profile_memory_snapshot_insert_trigger
    BEFORE INSERT ON profile_memory_snapshots
    FOR EACH ROW EXECUTE FUNCTION validate_profile_memory_snapshot();
    """)

    execute("""
    CREATE FUNCTION reject_profile_memory_snapshot_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'profile memory snapshots are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER profile_memory_snapshot_update_trigger
    BEFORE UPDATE ON profile_memory_snapshots
    FOR EACH ROW EXECUTE FUNCTION reject_profile_memory_snapshot_update();
    """)
  end

  def down do
    drop table(:profile_memory_sources)
    drop_if_exists table(:profile_memory_snapshots)
    drop table(:profile_memory_records)
    drop table(:profile_memory_scopes)
    execute("DROP FUNCTION IF EXISTS protect_profile_memory_record_identity()")
    execute("DROP FUNCTION IF EXISTS validate_profile_memory_source_scope()")
    execute("DROP FUNCTION IF EXISTS validate_profile_memory_record_support_trigger()")
    execute("DROP FUNCTION IF EXISTS validate_profile_memory_source_delete_trigger()")
    execute("DROP FUNCTION IF EXISTS validate_profile_memory_snapshot()")
    execute("DROP FUNCTION IF EXISTS reject_profile_memory_snapshot_update()")
    execute("DROP FUNCTION IF EXISTS validate_active_profile_memory_support(uuid)")
  end
end
