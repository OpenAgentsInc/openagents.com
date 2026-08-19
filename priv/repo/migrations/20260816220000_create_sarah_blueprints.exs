defmodule Sarah.Repo.Migrations.CreateSarahBlueprints do
  use Ecto.Migration

  def up do
    create table(:sarah_blueprint_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :revision, :string, null: false
      add :sequence, :bigint, null: false
      add :parent_revision, :string
      add :digest, :string, null: false
      add :status, :string, null: false, default: "admitted"
      add :compatibility_min, :integer, null: false
      add :compatibility_max, :integer, null: false
      add :author, :string, null: false
      add :reason, :text, null: false
      add :receipt, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:sarah_blueprint_revisions, [:revision])
    create unique_index(:sarah_blueprint_revisions, [:sequence])

    create constraint(:sarah_blueprint_revisions, :sarah_blueprint_revision_digest_check,
             check: "digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:sarah_blueprint_revisions, :sarah_blueprint_revision_status_check,
             check: "status IN ('admitted')"
           )

    create constraint(:sarah_blueprint_revisions, :sarah_blueprint_revision_compatibility_check,
             check: "compatibility_min >= 1 AND compatibility_max >= compatibility_min"
           )

    create constraint(:sarah_blueprint_revisions, :sarah_blueprint_revision_metadata_check,
             check:
               "octet_length(revision) BETWEEN 1 AND 100 AND " <>
                 "octet_length(author) BETWEEN 1 AND 200 AND " <>
                 "octet_length(reason) BETWEEN 1 AND 2000 AND " <>
                 "jsonb_typeof(receipt) = 'object' AND octet_length(receipt::text) <= 8192"
           )

    create table(:sarah_blueprint_facts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :revision_id,
          references(:sarah_blueprint_revisions, type: :binary_id, on_delete: :restrict),
          null: false

      add :fact_id, :string, null: false
      add :section, :string, null: false
      add :value_type, :string, null: false
      add :typed_value, :map, null: false
      add :source_type, :string, null: false
      add :source_ref, :string, null: false
      add :source_status, :string, null: false
      add :source_observed_at, :utc_datetime_usec, null: false
      add :source_digest, :string, null: false
      add :introduced_revision, :string, null: false
      add :retired_revision, :string
      add :compatibility_min, :integer, null: false
      add :compatibility_max, :integer, null: false
      add :capability_ref, :string
      add :promise_ref, :string
      add :author, :string, null: false
      add :reason, :text, null: false
      add :receipt, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:sarah_blueprint_facts, [:revision_id, :fact_id])
    create index(:sarah_blueprint_facts, [:fact_id, :introduced_revision])

    create constraint(:sarah_blueprint_facts, :sarah_blueprint_fact_section_check,
             check:
               "section IN ('identity', 'voice', 'vocabulary', 'roles', 'product_truths', 'rules', 'examples')"
           )

    create constraint(:sarah_blueprint_facts, :sarah_blueprint_fact_value_type_check,
             check: "value_type IN ('text', 'terms', 'role', 'example')"
           )

    create constraint(:sarah_blueprint_facts, :sarah_blueprint_fact_source_type_check,
             check:
               "source_type IN ('repository_document', 'release_artifact', 'persona_source', 'founder_direction')"
           )

    create constraint(:sarah_blueprint_facts, :sarah_blueprint_fact_source_status_check,
             check: "source_status IN ('admitted', 'binding', 'historical_evidence')"
           )

    create constraint(:sarah_blueprint_facts, :sarah_blueprint_fact_digest_check,
             check: "source_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:sarah_blueprint_facts, :sarah_blueprint_fact_compatibility_check,
             check: "compatibility_min >= 1 AND compatibility_max >= compatibility_min"
           )

    create constraint(:sarah_blueprint_facts, :sarah_blueprint_fact_bounds_check,
             check:
               "octet_length(fact_id) BETWEEN 1 AND 160 AND " <>
                 "octet_length(source_ref) BETWEEN 1 AND 1000 AND " <>
                 "octet_length(author) BETWEEN 1 AND 200 AND " <>
                 "octet_length(reason) BETWEEN 1 AND 2000 AND " <>
                 "jsonb_typeof(typed_value) = 'object' AND octet_length(typed_value::text) <= 8192 AND " <>
                 "jsonb_typeof(receipt) = 'object' AND octet_length(receipt::text) <= 8192"
           )

    execute("""
    CREATE FUNCTION reject_sarah_blueprint_mutation()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'admitted Sarah Blueprint records are immutable; append a revision';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER protect_sarah_blueprint_revisions
    BEFORE UPDATE OR DELETE ON sarah_blueprint_revisions
    FOR EACH ROW EXECUTE FUNCTION reject_sarah_blueprint_mutation();
    """)

    execute("""
    CREATE TRIGGER protect_sarah_blueprint_facts
    BEFORE UPDATE OR DELETE ON sarah_blueprint_facts
    FOR EACH ROW EXECUTE FUNCTION reject_sarah_blueprint_mutation();
    """)
  end

  def down do
    drop table(:sarah_blueprint_facts)
    drop table(:sarah_blueprint_revisions)
    execute("DROP FUNCTION reject_sarah_blueprint_mutation()")
  end
end
