defmodule Sarah.Repo.Migrations.CreateProgramLifecycle do
  use Ecto.Migration

  def up do
    create table(:program_lifecycle_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :artifact_id, :string, null: false
      add :signature_id, :string, null: false
      add :digest, :string, null: false
      add :stage, :string, null: false
      add :predecessor_artifact_id, :string
      add :document, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:program_lifecycle_artifacts, [:artifact_id])
    create unique_index(:program_lifecycle_artifacts, [:digest])
    create index(:program_lifecycle_artifacts, [:signature_id, :stage])

    create constraint(:program_lifecycle_artifacts, :program_artifact_stage_check,
             check: "stage IN ('candidate', 'approved', 'active')"
           )

    create constraint(:program_lifecycle_artifacts, :program_artifact_digest_check,
             check: "digest ~ '^[0-9a-f]{64}$' AND octet_length(document::text) <= 65536"
           )

    create table(:program_lifecycle_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :artifact_id, :string, null: false
      add :signature_id, :string, null: false
      add :event_type, :string, null: false
      add :actor_type, :string, null: false
      add :actor_id, :string, null: false
      add :receipt, :map, null: false
      add :previous_artifact_id, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:program_lifecycle_events, [:artifact_id, :event_type, :inserted_at])

    create constraint(:program_lifecycle_events, :program_event_type_check,
             check:
               "event_type IN ('compiled', 'evaluated', 'approved', 'activated', 'rolled_back')"
           )

    create constraint(:program_lifecycle_events, :program_actor_type_check,
             check: "actor_type IN ('compiler', 'evaluator', 'human')"
           )

    create constraint(:program_lifecycle_events, :program_event_bounds_check,
             check: "octet_length(receipt::text) <= 16384"
           )

    create table(:active_program_artifacts, primary_key: false) do
      add :signature_id, :string, primary_key: true
      add :artifact_id, :string, null: false
      add :artifact_digest, :string, null: false
      add :generation, :bigint, null: false

      add :activation_event_id,
          references(:program_lifecycle_events, type: :binary_id, on_delete: :restrict),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:active_program_artifacts, :active_program_generation_check,
             check: "generation > 0 AND artifact_digest ~ '^[0-9a-f]{64}$'"
           )

    execute("""
    CREATE FUNCTION reject_program_ledger_mutation()
    RETURNS trigger AS $$ BEGIN
      RAISE EXCEPTION 'program artifact and event ledgers are immutable';
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER protect_program_artifacts BEFORE UPDATE OR DELETE ON program_lifecycle_artifacts FOR EACH ROW EXECUTE FUNCTION reject_program_ledger_mutation()"
    )

    execute(
      "CREATE TRIGGER protect_program_events BEFORE UPDATE OR DELETE ON program_lifecycle_events FOR EACH ROW EXECUTE FUNCTION reject_program_ledger_mutation()"
    )

    execute("""
    CREATE FUNCTION enforce_active_program_transition()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'INSERT' AND NEW.generation <> 1 THEN
        RAISE EXCEPTION 'first program activation generation must be one';
      END IF;
      IF TG_OP = 'UPDATE' AND NEW.generation <> OLD.generation + 1 THEN
        RAISE EXCEPTION 'program activation generation must advance exactly once';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM program_lifecycle_artifacts a
        WHERE a.artifact_id = NEW.artifact_id
          AND a.signature_id = NEW.signature_id
          AND a.digest = NEW.artifact_digest
          AND a.stage = 'active'
      ) THEN
        RAISE EXCEPTION 'active program requires a matching immutable artifact';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM program_lifecycle_events e
        WHERE e.id = NEW.activation_event_id
          AND e.signature_id = NEW.signature_id
          AND e.artifact_id = NEW.artifact_id
          AND e.actor_type = 'human'
          AND e.event_type IN ('activated', 'rolled_back')
      ) THEN
        RAISE EXCEPTION 'active program requires a matching human lifecycle event';
      END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER enforce_active_program_transition_trigger BEFORE INSERT OR UPDATE ON active_program_artifacts FOR EACH ROW EXECUTE FUNCTION enforce_active_program_transition()"
    )
  end

  def down do
    drop table(:active_program_artifacts)
    execute("DROP FUNCTION enforce_active_program_transition()")
    drop table(:program_lifecycle_events)
    drop table(:program_lifecycle_artifacts)
    execute("DROP FUNCTION reject_program_ledger_mutation()")
  end
end
