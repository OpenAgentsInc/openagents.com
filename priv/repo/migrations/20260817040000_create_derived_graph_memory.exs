defmodule Sarah.Repo.Migrations.CreateDerivedGraphMemory do
  use Ecto.Migration

  def up do
    create table(:graph_manifests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id, references(:visitors, type: :binary_id, on_delete: :delete_all),
        null: false

      add :work_scope, :string, null: false
      add :generation, :bigint, null: false
      add :status, :string, null: false
      add :policy_id, :string, null: false
      add :policy_version, :integer, null: false
      add :source_snapshot_digest, :string, null: false
      add :build_digest, :string
      add :node_count, :integer, null: false, default: 0
      add :edge_count, :integer, null: false, default: 0
      add :failure_code, :string
      add :built_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:graph_manifests, [:owner_visitor_id, :work_scope, :generation])

    create unique_index(:graph_manifests, [:owner_visitor_id, :work_scope],
             where: "status='current'",
             name: :one_current_graph_generation
           )

    create table(:graph_artifacts, primary_key: false) do
      add :manifest_id, references(:graph_manifests, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :artifact_id, :string, primary_key: true
      add :owner_visitor_id, :binary_id, null: false
      add :work_scope, :string, null: false
      add :kind, :string, null: false
      add :entity_kind, :string
      add :identity_key, :string
      add :version_key, :string
      add :conflict_key, :string
      add :source_node_id, :string
      add :target_node_id, :string
      add :predicate, :string
      add :properties, :map, null: false, default: %{}
      add :artifact_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:graph_artifacts, [:manifest_id, :kind, :entity_kind])
    create index(:graph_artifacts, [:manifest_id, :source_node_id, :predicate])
    create index(:graph_artifacts, [:manifest_id, :conflict_key])

    create table(:graph_source_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :manifest_id, :binary_id, null: false
      add :artifact_id, :string, null: false
      add :owner_visitor_id, :binary_id, null: false
      add :work_scope, :string, null: false
      add :source_kind, :string, null: false
      add :source_ref, :string, null: false
      add :source_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:graph_source_memberships, [:manifest_id, :artifact_id, :source_ref],
             name: :graph_membership_identity
           )

    create index(:graph_source_memberships, [:owner_visitor_id, :work_scope, :source_ref],
             name: :graph_membership_source_index
           )

    create table(:graph_mutation_outbox, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_visitor_id, :binary_id, null: false
      add :work_scope, :string, null: false
      add :source_kind, :string, null: false
      add :source_ref, :string, null: false
      add :source_generation, :bigint, null: false
      add :source_digest, :string, null: false
      add :operation, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :consumed_manifest_id, :binary_id
      add :consumed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:graph_mutation_outbox, [:owner_visitor_id, :work_scope, :status, :id],
             name: :graph_outbox_scope_status
           )

    create table(:graph_cascade_plans, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_visitor_id, :binary_id, null: false
      add :work_scope, :string, null: false
      add :manifest_id, :binary_id, null: false
      add :source_ref, :string, null: false
      add :source_snapshot_digest, :string, null: false
      add :artifact_ids, {:array, :string}, null: false, default: []
      add :node_count, :integer, null: false
      add :edge_count, :integer, null: false
      add :plan_digest, :string, null: false
      add :status, :string, null: false, default: "planned"
      add :applied_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create table(:graph_operation_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_visitor_id, :binary_id, null: false
      add :work_scope, :string, null: false
      add :operation, :string, null: false
      add :manifest_ref, :string
      add :plan_ref, :string
      add :source_snapshot_digest, :string, null: false
      add :deleted_node_count, :integer, null: false, default: 0
      add :deleted_edge_count, :integer, null: false, default: 0
      add :receipt_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:graph_manifests, :graph_manifest_shape,
             check:
               "generation > 0 AND status IN ('building','current','retired','failed') AND policy_version > 0 AND source_snapshot_digest ~ '^[0-9a-f]{64}$' AND (build_digest IS NULL OR build_digest ~ '^[0-9a-f]{64}$') AND node_count >= 0 AND edge_count >= 0"
           )

    create constraint(:graph_artifacts, :graph_artifact_shape,
             check:
               "kind IN ('node','edge') AND artifact_id ~ '^[0-9a-f]{64}$' AND artifact_digest ~ '^[0-9a-f]{64}$' AND octet_length(properties::text) <= 2000 AND ((kind='node' AND entity_kind IS NOT NULL AND identity_key IS NOT NULL AND source_node_id IS NULL AND target_node_id IS NULL AND predicate IS NULL) OR (kind='edge' AND entity_kind IS NULL AND identity_key IS NULL AND source_node_id IS NOT NULL AND target_node_id IS NOT NULL AND predicate IS NOT NULL))"
           )

    create constraint(:graph_source_memberships, :graph_membership_shape,
             check:
               "source_kind IN ('experience_record','experience_pattern') AND octet_length(source_ref) BETWEEN 1 AND 256 AND source_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:graph_mutation_outbox, :graph_outbox_shape,
             check:
               "source_kind IN ('experience_record','experience_pattern') AND operation IN ('insert','update','delete') AND status IN ('pending','consumed') AND source_generation > 0 AND source_digest ~ '^[0-9a-f]{64}$' AND ((status='pending' AND consumed_manifest_id IS NULL AND consumed_at IS NULL) OR (status='consumed' AND consumed_manifest_id IS NOT NULL AND consumed_at IS NOT NULL))"
           )

    create constraint(:graph_cascade_plans, :graph_cascade_plan_shape,
             check:
               "status IN ('planned','applied','stale') AND node_count >= 0 AND edge_count >= 0 AND source_snapshot_digest ~ '^[0-9a-f]{64}$' AND plan_digest ~ '^[0-9a-f]{64}$' AND ((status='planned' AND applied_at IS NULL) OR (status<>'planned' AND applied_at IS NOT NULL))"
           )

    create constraint(:graph_operation_receipts, :graph_operation_receipt_shape,
             check:
               "operation IN ('rebuild','replay','recover','cascade','drop') AND source_snapshot_digest ~ '^[0-9a-f]{64}$' AND deleted_node_count >= 0 AND deleted_edge_count >= 0 AND receipt_digest ~ '^[0-9a-f]{64}$'"
           )

    execute("""
    CREATE FUNCTION validate_graph_artifact_scope() RETURNS trigger AS $$
    DECLARE manifest_owner uuid; manifest_work text; manifest_status text;
    BEGIN
      SELECT owner_visitor_id,work_scope,status INTO manifest_owner,manifest_work,manifest_status FROM graph_manifests WHERE id=NEW.manifest_id;
      IF manifest_owner IS NULL OR manifest_owner<>NEW.owner_visitor_id OR manifest_work<>NEW.work_scope OR manifest_status<>'building'
      THEN RAISE EXCEPTION 'graph artifact scope or generation mismatch'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER graph_artifact_scope BEFORE INSERT ON graph_artifacts FOR EACH ROW EXECUTE FUNCTION validate_graph_artifact_scope()"
    )

    execute("""
    CREATE FUNCTION validate_graph_membership() RETURNS trigger AS $$
    DECLARE artifact_owner uuid; artifact_work text; source_owner uuid; source_work text; authoritative_digest text; expected_ref text;
    BEGIN
      SELECT owner_visitor_id,work_scope INTO artifact_owner,artifact_work FROM graph_artifacts WHERE manifest_id=NEW.manifest_id AND artifact_id=NEW.artifact_id;
      IF artifact_owner IS NULL OR artifact_owner<>NEW.owner_visitor_id OR artifact_work<>NEW.work_scope
      THEN RAISE EXCEPTION 'graph membership scope mismatch'; END IF;
      IF NEW.source_kind='experience_record' THEN
        SELECT owner_visitor_id,work_scope,content_digest,'experience:' || id::text INTO source_owner,source_work,authoritative_digest,expected_ref FROM experience_records WHERE 'experience:' || id::text=NEW.source_ref;
      ELSE
        SELECT owner_visitor_id,work_scope,digest,'experience-pattern:' || id::text INTO source_owner,source_work,authoritative_digest,expected_ref FROM experience_patterns WHERE 'experience-pattern:' || id::text=NEW.source_ref;
      END IF;
      IF source_owner IS NULL OR source_owner<>NEW.owner_visitor_id OR source_work<>NEW.work_scope OR authoritative_digest<>NEW.source_digest OR expected_ref<>NEW.source_ref
      THEN RAISE EXCEPTION 'graph membership source provenance mismatch'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER graph_membership_scope BEFORE INSERT ON graph_source_memberships FOR EACH ROW EXECUTE FUNCTION validate_graph_membership()"
    )

    execute("""
    CREATE FUNCTION validate_graph_artifact_membership() RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM graph_source_memberships m WHERE m.manifest_id=NEW.manifest_id AND m.artifact_id=NEW.artifact_id)
      THEN RAISE EXCEPTION 'graph artifact requires source membership'; END IF;
      IF NEW.kind='edge' AND (NOT EXISTS (SELECT 1 FROM graph_artifacts n WHERE n.manifest_id=NEW.manifest_id AND n.artifact_id=NEW.source_node_id AND n.kind='node') OR NOT EXISTS (SELECT 1 FROM graph_artifacts n WHERE n.manifest_id=NEW.manifest_id AND n.artifact_id=NEW.target_node_id AND n.kind='node'))
      THEN RAISE EXCEPTION 'graph edge endpoint missing'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE CONSTRAINT TRIGGER graph_artifact_membership AFTER INSERT ON graph_artifacts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_graph_artifact_membership()"
    )

    execute(
      "CREATE FUNCTION reject_graph_projection_update() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'graph projections are immutable'; END; $$ LANGUAGE plpgsql;"
    )

    for table <- ["graph_artifacts", "graph_source_memberships", "graph_operation_receipts"] do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION reject_graph_projection_update()"
      )
    end

    execute(
      "CREATE TRIGGER graph_operation_receipts_append_only BEFORE DELETE ON graph_operation_receipts FOR EACH ROW EXECUTE FUNCTION reject_graph_projection_update()"
    )

    execute("""
    CREATE FUNCTION protect_graph_manifest_transition() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.owner_visitor_id,OLD.work_scope,OLD.generation,OLD.policy_id,OLD.policy_version,OLD.source_snapshot_digest,OLD.inserted_at) IS DISTINCT FROM ROW(NEW.owner_visitor_id,NEW.work_scope,NEW.generation,NEW.policy_id,NEW.policy_version,NEW.source_snapshot_digest,NEW.inserted_at)
      THEN RAISE EXCEPTION 'graph manifest identity is immutable'; END IF;
      IF NOT ((OLD.status='building' AND NEW.status IN ('current','failed')) OR (OLD.status='current' AND NEW.status='retired'))
      THEN RAISE EXCEPTION 'invalid graph manifest transition'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER graph_manifest_transition BEFORE UPDATE ON graph_manifests FOR EACH ROW EXECUTE FUNCTION protect_graph_manifest_transition()"
    )

    execute("""
    CREATE FUNCTION protect_graph_outbox_transition() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.owner_visitor_id,OLD.work_scope,OLD.source_kind,OLD.source_ref,OLD.source_generation,OLD.source_digest,OLD.operation,OLD.inserted_at) IS DISTINCT FROM ROW(NEW.owner_visitor_id,NEW.work_scope,NEW.source_kind,NEW.source_ref,NEW.source_generation,NEW.source_digest,NEW.operation,NEW.inserted_at)
      THEN RAISE EXCEPTION 'graph outbox identity is immutable'; END IF;
      IF NOT (OLD.status='pending' AND NEW.status='consumed')
      THEN RAISE EXCEPTION 'invalid graph outbox transition'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER graph_outbox_transition BEFORE UPDATE ON graph_mutation_outbox FOR EACH ROW EXECUTE FUNCTION protect_graph_outbox_transition()"
    )

    execute("""
    CREATE FUNCTION protect_graph_cascade_plan() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.owner_visitor_id,OLD.work_scope,OLD.manifest_id,OLD.source_ref,OLD.source_snapshot_digest,OLD.artifact_ids,OLD.node_count,OLD.edge_count,OLD.plan_digest,OLD.inserted_at) IS DISTINCT FROM ROW(NEW.owner_visitor_id,NEW.work_scope,NEW.manifest_id,NEW.source_ref,NEW.source_snapshot_digest,NEW.artifact_ids,NEW.node_count,NEW.edge_count,NEW.plan_digest,NEW.inserted_at)
      THEN RAISE EXCEPTION 'graph cascade plan identity is immutable'; END IF;
      IF NOT (OLD.status='planned' AND NEW.status IN ('applied','stale'))
      THEN RAISE EXCEPTION 'invalid graph cascade plan transition'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER graph_cascade_plan_transition BEFORE UPDATE ON graph_cascade_plans FOR EACH ROW EXECUTE FUNCTION protect_graph_cascade_plan()"
    )

    execute(
      "CREATE FUNCTION reject_experience_pattern_update() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'experience patterns are immutable; rebuild from cases'; END; $$ LANGUAGE plpgsql;"
    )

    execute(
      "CREATE TRIGGER experience_patterns_immutable BEFORE UPDATE ON experience_patterns FOR EACH ROW EXECUTE FUNCTION reject_experience_pattern_update()"
    )

    execute("""
    CREATE FUNCTION enqueue_experience_graph_mutation() RETURNS trigger AS $$
    DECLARE source_row record; operation_value text; kind_value text; ref_value text; digest_value text; generation_value bigint;
    BEGIN
      IF TG_OP='DELETE' THEN source_row := OLD; ELSE source_row := NEW; END IF;
      operation_value := lower(TG_OP);
      IF TG_TABLE_NAME='experience_records' THEN
        kind_value := 'experience_record'; ref_value := 'experience:' || source_row.id::text; digest_value := source_row.content_digest; generation_value := source_row.scope_generation;
      ELSE
        kind_value := 'experience_pattern'; ref_value := 'experience-pattern:' || source_row.id::text; digest_value := source_row.digest; generation_value := source_row.generation;
      END IF;
      INSERT INTO graph_mutation_outbox(id,owner_visitor_id,work_scope,source_kind,source_ref,source_generation,source_digest,operation,status,inserted_at,updated_at)
      VALUES(gen_random_uuid(),source_row.owner_visitor_id,source_row.work_scope,kind_value,ref_value,generation_value,digest_value,operation_value,'pending',now(),now());
      RETURN COALESCE(NEW,OLD);
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER experience_records_graph_outbox AFTER INSERT OR UPDATE OR DELETE ON experience_records FOR EACH ROW EXECUTE FUNCTION enqueue_experience_graph_mutation()"
    )

    execute(
      "CREATE TRIGGER experience_patterns_graph_outbox AFTER INSERT OR UPDATE OR DELETE ON experience_patterns FOR EACH ROW EXECUTE FUNCTION enqueue_experience_graph_mutation()"
    )
  end

  def down do
    execute("DROP FUNCTION IF EXISTS enqueue_experience_graph_mutation() CASCADE")
    execute("DROP FUNCTION IF EXISTS reject_experience_pattern_update() CASCADE")
    execute("DROP FUNCTION IF EXISTS protect_graph_cascade_plan() CASCADE")
    execute("DROP FUNCTION IF EXISTS protect_graph_outbox_transition() CASCADE")
    execute("DROP FUNCTION IF EXISTS protect_graph_manifest_transition() CASCADE")
    execute("DROP FUNCTION IF EXISTS reject_graph_projection_update() CASCADE")
    execute("DROP FUNCTION IF EXISTS validate_graph_artifact_membership() CASCADE")
    execute("DROP FUNCTION IF EXISTS validate_graph_membership() CASCADE")
    execute("DROP FUNCTION IF EXISTS validate_graph_artifact_scope() CASCADE")
    drop table(:graph_operation_receipts)
    drop table(:graph_cascade_plans)
    drop table(:graph_mutation_outbox)
    drop table(:graph_source_memberships)
    drop table(:graph_artifacts)
    drop table(:graph_manifests)
  end
end
