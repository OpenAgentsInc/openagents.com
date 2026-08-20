defmodule OpenAgents.Repo.Migrations.HardenAsyncRuntimeBoundaries do
  use Ecto.Migration

  def up do
    create constraint(:messages, :messages_content_hard_bound,
             check: "octet_length(content) <= 1048576"
           )

    create unique_index(:messages, [:id, :conversation_id],
             name: :messages_id_conversation_id_index
           )

    execute("""
    ALTER TABLE semantic_embedding_jobs
    ADD CONSTRAINT semantic_jobs_message_scope_fk
    FOREIGN KEY (message_id, conversation_id)
    REFERENCES messages(id, conversation_id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE message_semantic_embeddings
    ADD CONSTRAINT semantic_embeddings_message_scope_fk
    FOREIGN KEY (message_id, conversation_id)
    REFERENCES messages(id, conversation_id)
    ON DELETE CASCADE
    """)

    alter table(:work_jobs) do
      add :machine_id, references(:machines, type: :binary_id, on_delete: :restrict)
      add :authority_snapshot, :map
      add :budget_snapshot, :map
    end

    create index(:work_jobs, [:machine_id, :inserted_at])

    execute("""
    UPDATE work_jobs AS job
    SET machine_id = machine.id,
        authority_snapshot = jsonb_build_object(
          'machine_tier', machine.tier,
          'roots', machine.roots,
          'cwd', COALESCE(job.delegation->>'cwd', ''),
          'agent_id', COALESCE(job.delegation->>'agent_id', ''),
          'machine_name', COALESCE(job.delegation->>'machine_name', machine.name)
        ),
        budget_snapshot = jsonb_build_object(
          'wall_clock_ms', CASE
            WHEN job.delegation->>'timeout_ms' ~ '^[0-9]+$'
              THEN (job.delegation->>'timeout_ms')::integer
            ELSE 3600000
          END,
          'maximum_prompt_bytes', 8000,
          'maximum_report_bytes', 8000
        )
    FROM machines AS machine
    WHERE job.kind = 'delegation'
      AND job.delegation->>'machine_id' = machine.id::text
    """)

    create constraint(:work_jobs, :work_jobs_delegation_identity,
             check:
               "kind <> 'delegation' OR (machine_id IS NOT NULL AND jsonb_typeof(delegation) = 'object' AND jsonb_typeof(authority_snapshot) = 'object' AND jsonb_typeof(budget_snapshot) = 'object' AND octet_length(authority_snapshot::text) <= 32768 AND octet_length(budget_snapshot::text) <= 4096 AND jsonb_typeof(authority_snapshot->'roots') = 'array' AND jsonb_array_length(authority_snapshot->'roots') > 0 AND authority_snapshot->>'machine_tier' IN ('probe', 'curated', 'shell') AND jsonb_typeof(authority_snapshot->'agent_id') = 'string' AND octet_length(authority_snapshot->>'agent_id') BETWEEN 1 AND 64 AND jsonb_typeof(authority_snapshot->'cwd') = 'string' AND octet_length(authority_snapshot->>'cwd') BETWEEN 1 AND 500 AND jsonb_typeof(authority_snapshot->'machine_name') = 'string' AND octet_length(authority_snapshot->>'machine_name') BETWEEN 1 AND 256 AND jsonb_typeof(delegation->'prompt') = 'string' AND octet_length(delegation->>'prompt') BETWEEN 1 AND 8000 AND jsonb_typeof(delegation->'timeout_ms') = 'number' AND jsonb_typeof(budget_snapshot->'wall_clock_ms') = 'number' AND (budget_snapshot->>'wall_clock_ms')::numeric BETWEEN 1 AND 3600000 AND jsonb_typeof(budget_snapshot->'maximum_prompt_bytes') = 'number' AND (budget_snapshot->>'maximum_prompt_bytes')::numeric BETWEEN 1 AND 8000 AND jsonb_typeof(budget_snapshot->'maximum_report_bytes') = 'number' AND (budget_snapshot->>'maximum_report_bytes')::numeric = 8000 AND delegation->>'machine_id' = machine_id::text AND delegation->>'agent_id' = authority_snapshot->>'agent_id' AND delegation->>'cwd' = authority_snapshot->>'cwd' AND delegation->>'machine_name' = authority_snapshot->>'machine_name' AND (delegation->>'timeout_ms')::numeric = (budget_snapshot->>'wall_clock_ms')::numeric AND octet_length(delegation->>'prompt') <= (budget_snapshot->>'maximum_prompt_bytes')::numeric)"
           )

    execute("""
    CREATE FUNCTION enforce_work_job_scope()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM conversations
        WHERE id = NEW.conversation_id AND visitor_id = NEW.owner_visitor_id
      ) THEN
        RAISE EXCEPTION 'work job conversation owner mismatch';
      END IF;

      IF NEW.kind = 'delegation' AND NOT EXISTS (
        SELECT 1
        FROM machines AS machine
        JOIN visitors AS visitor ON visitor.id = NEW.owner_visitor_id
        WHERE machine.id = NEW.machine_id
          AND visitor.user_id IS NOT NULL
          AND machine.user_id = visitor.user_id
      ) THEN
        RAISE EXCEPTION 'work job machine owner mismatch';
      END IF;

      IF TG_OP = 'INSERT' AND NEW.kind = 'delegation' AND NOT EXISTS (
        SELECT 1
        FROM machines AS machine
        WHERE machine.id = NEW.machine_id
          AND NEW.authority_snapshot->>'machine_tier' = machine.tier
          AND NEW.authority_snapshot->'roots' = to_jsonb(machine.roots)
          AND NEW.authority_snapshot->>'machine_name' = machine.name
      ) THEN
        RAISE EXCEPTION 'work job machine authority snapshot mismatch';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER work_jobs_enforce_scope
    BEFORE INSERT OR UPDATE ON work_jobs
    FOR EACH ROW
    EXECUTE FUNCTION enforce_work_job_scope();
    """)

    execute(identity_function(true))
  end

  def down do
    execute(identity_function(false))
    execute("DROP TRIGGER IF EXISTS work_jobs_enforce_scope ON work_jobs")
    execute("DROP FUNCTION IF EXISTS enforce_work_job_scope()")
    drop constraint(:work_jobs, :work_jobs_delegation_identity)
    drop index(:work_jobs, [:machine_id, :inserted_at])

    alter table(:work_jobs) do
      remove :budget_snapshot
      remove :authority_snapshot
      remove :machine_id
    end

    execute(
      "ALTER TABLE message_semantic_embeddings DROP CONSTRAINT IF EXISTS semantic_embeddings_message_scope_fk"
    )

    execute(
      "ALTER TABLE semantic_embedding_jobs DROP CONSTRAINT IF EXISTS semantic_jobs_message_scope_fk"
    )

    drop_if_exists index(:messages, [:id, :conversation_id],
                     name: :messages_id_conversation_id_index
                   )

    drop constraint(:messages, :messages_content_hard_bound)
  end

  defp identity_function(include_delegation_identity?) do
    extra_old =
      if include_delegation_identity?,
        do:
          ", OLD.kind, CASE WHEN OLD.kind = 'delegation' THEN OLD.delegation - 'resume_session_id' ELSE NULL END, OLD.machine_id, OLD.authority_snapshot, OLD.budget_snapshot",
        else: ""

    extra_new =
      if include_delegation_identity?,
        do:
          ", NEW.kind, CASE WHEN NEW.kind = 'delegation' THEN NEW.delegation - 'resume_session_id' ELSE NULL END, NEW.machine_id, NEW.authority_snapshot, NEW.budget_snapshot",
        else: ""

    """
    CREATE OR REPLACE FUNCTION enforce_work_job_transition()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        OLD.conversation_id, OLD.owner_visitor_id, OLD.surface, OLD.goal,
        OLD.context_hint, OLD.requesting_tool_step_ref#{extra_old}
      ) IS DISTINCT FROM ROW(
        NEW.conversation_id, NEW.owner_visitor_id, NEW.surface, NEW.goal,
        NEW.context_hint, NEW.requesting_tool_step_ref#{extra_new}
      ) THEN
        RAISE EXCEPTION 'work job identity is immutable';
      END IF;

      IF OLD.status = 'queued' AND NEW.status NOT IN (
        'queued', 'running', 'failed', 'interrupted', 'cancelled'
      ) THEN
        RAISE EXCEPTION 'invalid queued work job transition';
      END IF;

      IF OLD.status = 'running' AND NEW.status NOT IN (
        'running', 'completed', 'failed', 'interrupted', 'budget_exhausted', 'cancelled'
      ) THEN
        RAISE EXCEPTION 'invalid running work job transition';
      END IF;

      IF OLD.status NOT IN ('queued', 'running') AND ROW(
        OLD.status, OLD.report, OLD.error_code, OLD.usage, OLD.completed_at
      ) IS DISTINCT FROM ROW(
        NEW.status, NEW.report, NEW.error_code, NEW.usage, NEW.completed_at
      ) THEN
        RAISE EXCEPTION 'terminal work job is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
