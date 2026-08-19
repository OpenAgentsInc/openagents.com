defmodule Sarah.Repo.Migrations.CreateSemanticRecallDerivatives do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vector")
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")

    create table(:semantic_index_manifests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :generation, :integer, null: false
      add :model_id, :string, null: false
      add :model_version, :string, null: false
      add :dimensions, :integer, null: false
      add :ranking_policy_id, :string, null: false
      add :ranking_policy_version, :integer, null: false
      add :manifest_digest, :string, null: false
      add :status, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:semantic_index_manifests, [:generation])

    create unique_index(:semantic_index_manifests, [:status],
             where: "status = 'active'",
             name: :one_active_semantic_manifest
           )

    create table(:semantic_embedding_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :manifest_id,
          references(:semantic_index_manifests, type: :binary_id, on_delete: :restrict),
          null: false

      add :generation, :integer, null: false
      add :model_id, :string, null: false
      add :model_version, :string, null: false
      add :dimensions, :integer, null: false
      add :content_digest, :string, null: false
      add :status, :string, null: false
      add :attempts, :integer, null: false, default: 0
      add :error_code, :string
      add :available_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:semantic_embedding_jobs, [:message_id, :generation])
    create index(:semantic_embedding_jobs, [:status, :available_at])

    execute("""
    CREATE TABLE message_semantic_embeddings (
      id uuid PRIMARY KEY,
      message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
      conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      manifest_id uuid NOT NULL REFERENCES semantic_index_manifests(id) ON DELETE RESTRICT,
      generation integer NOT NULL,
      model_id varchar(255) NOT NULL,
      model_version varchar(255) NOT NULL,
      dimensions integer NOT NULL,
      content_digest varchar(64) NOT NULL,
      status varchar(32) NOT NULL DEFAULT 'ready',
      embedding vector(64) NOT NULL,
      inserted_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CHECK (status IN ('ready')),
      UNIQUE(message_id, generation)
    )
    """)

    execute(
      "CREATE INDEX message_semantic_embeddings_scope_index ON message_semantic_embeddings(conversation_id, generation)"
    )

    execute(
      "CREATE INDEX message_semantic_embeddings_vector_index ON message_semantic_embeddings USING hnsw (embedding vector_cosine_ops)"
    )

    create table(:semantic_derivative_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :message_id, :binary_id, null: false
      add :conversation_id, :binary_id, null: false
      add :content_digest, :string, null: false
      add :action, :string, null: false
      add :reason_code, :string, null: false
      add :generation, :integer, null: false
      add :deleted_embedding_count, :integer, null: false
      add :invalidated_job_count, :integer, null: false
      add :receipt_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:semantic_index_manifests, :semantic_manifest_shape,
             check:
               "generation > 0 AND dimensions = 64 AND status IN ('active','retired') AND manifest_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:semantic_embedding_jobs, :semantic_job_shape,
             check:
               "generation > 0 AND dimensions = 64 AND attempts >= 0 AND status IN ('pending','running','completed','failed','invalidated') AND content_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:semantic_derivative_receipts, :semantic_derivative_receipt_shape,
             check:
               "action IN ('invalidate','delete','rebuild') AND generation > 0 AND deleted_embedding_count >= 0 AND invalidated_job_count >= 0 AND content_digest ~ '^[0-9a-f]{64}$' AND receipt_digest ~ '^[0-9a-f]{64}$'"
           )

    execute("""
    CREATE FUNCTION enqueue_semantic_embedding_job() RETURNS trigger AS $$
    DECLARE active_manifest semantic_index_manifests%ROWTYPE;
    DECLARE digest_value text;
    DECLARE deleted_count integer;
    DECLARE invalidated_count integer;
    DECLARE receipt_projection text;
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.content IS NOT DISTINCT FROM NEW.content
         AND OLD.status IS NOT DISTINCT FROM NEW.status THEN
        RETURN NEW;
      END IF;

      IF NEW.status <> 'complete' OR NEW.role NOT IN ('user','assistant') THEN
        RETURN NEW;
      END IF;

      SELECT * INTO active_manifest FROM semantic_index_manifests WHERE status = 'active' LIMIT 1;
      IF active_manifest.id IS NULL THEN RETURN NEW; END IF;

      digest_value := encode(digest(NEW.content, 'sha256'), 'hex');
      SELECT count(*) INTO invalidated_count FROM semantic_embedding_jobs
      WHERE message_id = NEW.id AND status IN ('pending','running','completed','failed');

      DELETE FROM message_semantic_embeddings
      WHERE message_id = NEW.id AND (generation <> active_manifest.generation OR content_digest <> digest_value);
      GET DIAGNOSTICS deleted_count = ROW_COUNT;

      INSERT INTO semantic_embedding_jobs (
        id, message_id, conversation_id, manifest_id, generation, model_id,
        model_version, dimensions, content_digest, status, attempts,
        available_at, inserted_at, updated_at
      ) VALUES (
        gen_random_uuid(), NEW.id, NEW.conversation_id, active_manifest.id,
        active_manifest.generation, active_manifest.model_id,
        active_manifest.model_version, active_manifest.dimensions, digest_value,
        'pending', 0, now(), now(), now()
      ) ON CONFLICT (message_id, generation) DO UPDATE SET
        content_digest = EXCLUDED.content_digest, status = 'pending', error_code = NULL,
        available_at = now(), started_at = NULL, completed_at = NULL, updated_at = now();

      IF TG_OP = 'UPDATE' AND OLD.content IS DISTINCT FROM NEW.content THEN
        receipt_projection := concat_ws('|', NEW.id, NEW.conversation_id,
          encode(digest(OLD.content, 'sha256'), 'hex'), 'invalidate',
          'source_content_changed', active_manifest.generation, deleted_count,
          invalidated_count);

        INSERT INTO semantic_derivative_receipts (
          id,message_id,conversation_id,content_digest,action,reason_code,generation,
          deleted_embedding_count,invalidated_job_count,receipt_digest,inserted_at
        ) VALUES (
          gen_random_uuid(),NEW.id,NEW.conversation_id,
          encode(digest(OLD.content, 'sha256'), 'hex'),'invalidate',
          'source_content_changed',active_manifest.generation,deleted_count,
          invalidated_count,encode(digest(receipt_projection, 'sha256'), 'hex'),now()
        );
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER messages_enqueue_semantic_embedding AFTER INSERT OR UPDATE OF content, status ON messages FOR EACH ROW EXECUTE FUNCTION enqueue_semantic_embedding_job()"
    )

    execute("""
    CREATE FUNCTION reject_semantic_receipt_mutation() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'semantic derivative receipts are append-only'; END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER semantic_derivative_receipts_append_only BEFORE UPDATE OR DELETE ON semantic_derivative_receipts FOR EACH ROW EXECUTE FUNCTION reject_semantic_receipt_mutation()"
    )
  end

  def down do
    execute("DROP TRIGGER IF EXISTS messages_enqueue_semantic_embedding ON messages")
    execute("DROP FUNCTION IF EXISTS enqueue_semantic_embedding_job()")
    execute("DROP FUNCTION IF EXISTS reject_semantic_receipt_mutation() CASCADE")
    drop table(:semantic_derivative_receipts)
    execute("DROP TABLE message_semantic_embeddings")
    drop table(:semantic_embedding_jobs)
    drop table(:semantic_index_manifests)
  end
end
