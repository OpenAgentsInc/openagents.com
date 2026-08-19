defmodule OpenAgents.Memory.SemanticIndex do
  @moduledoc "Rebuildable pgvector index, asynchronous outbox, and deletion receipts."

  import Ecto.Query

  alias OpenAgents.Conversations.Message
  alias OpenAgents.Memory.{SemanticDerivativeReceipt, SemanticJob, SemanticManifest}
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  @ranking_policy %{
    "id" => "sarah.recall.hybrid_rrf.v1",
    "version" => 1,
    "lexical_weight" => 65,
    "semantic_weight" => 35,
    "rrf_constant" => 60,
    "tie_break" => "observed_at_desc_message_id_desc"
  }

  @spec ensure_manifest!(map()) :: SemanticManifest.t()
  def ensure_manifest!(config) do
    case active_manifest() do
      %SemanticManifest{} = manifest
      when manifest.model_id == config.model_id and
             manifest.model_version == config.model_version and
             manifest.dimensions == config.dimensions ->
        manifest

      _missing_or_changed ->
        case install_manifest(config) do
          {:ok, manifest} -> manifest
          {:error, reason} -> raise "semantic manifest admission failed: #{inspect(reason)}"
        end
    end
  end

  @spec install_manifest(map()) :: {:ok, SemanticManifest.t()} | {:error, term()}
  def install_manifest(config) do
    with :ok <- validate_config(config) do
      Repo.transaction(fn ->
        generation = Repo.aggregate(SemanticManifest, :max, :generation) || 0

        _retired =
          Repo.update_all(from(manifest in SemanticManifest, where: manifest.status == "active"),
            set: [status: "retired"]
          )

        projection = %{
          "generation" => generation + 1,
          "model_id" => config.model_id,
          "model_version" => config.model_version,
          "dimensions" => config.dimensions,
          "ranking_policy" => @ranking_policy
        }

        manifest =
          %SemanticManifest{}
          |> SemanticManifest.changeset(%{
            generation: generation + 1,
            model_id: config.model_id,
            model_version: config.model_version,
            dimensions: config.dimensions,
            ranking_policy_id: @ranking_policy["id"],
            ranking_policy_version: @ranking_policy["version"],
            manifest_digest: Canonical.digest!(projection),
            status: "active"
          })
          |> insert_or_rollback()

        backfill!(manifest)
        manifest
      end)
    end
  end

  @spec active_manifest() :: SemanticManifest.t() | nil
  def active_manifest,
    do: Repo.one(from(manifest in SemanticManifest, where: manifest.status == "active", limit: 1))

  @spec generation_ready?(Ecto.UUID.t(), pos_integer()) :: boolean()
  def generation_ready?(conversation_id, generation) do
    not Repo.exists?(
      from(job in SemanticJob,
        where:
          job.conversation_id == ^conversation_id and job.generation == ^generation and
            job.status != "completed"
      )
    )
  end

  @spec process_next(module()) :: {:ok, :empty | :completed | :failed | :invalidated}
  def process_next(provider) when is_atom(provider) do
    case claim_job() do
      nil -> {:ok, :empty}
      job -> execute_job(job, provider)
    end
  end

  @spec process_all(module(), pos_integer()) :: map()
  def process_all(provider, limit \\ 100) do
    Enum.reduce_while(1..limit, %{completed: 0, failed: 0, invalidated: 0}, fn _index, counts ->
      case process_next(provider) do
        {:ok, :empty} -> {:halt, counts}
        {:ok, status} -> {:cont, Map.update!(counts, status, &(&1 + 1))}
      end
    end)
  end

  @spec invalidate(Message.t(), String.t(), String.t()) ::
          {:ok, SemanticDerivativeReceipt.t()} | {:error, term()}
  def invalidate(%Message{} = message, action, reason_code)
      when action in ~w(invalidate delete rebuild) and is_binary(reason_code) do
    Repo.transaction(fn -> invalidate_locked(message, action, reason_code) end)
    |> transaction_result()
  end

  @spec rebuild(map()) :: {:ok, SemanticManifest.t()} | {:error, term()}
  def rebuild(config) do
    messages =
      Repo.all(
        from(message in Message,
          where: message.status == "complete" and message.role in ["user", "assistant"]
        )
      )

    Enum.each(messages, fn message ->
      {:ok, _receipt} = invalidate(message, "rebuild", "manifest_rebuild")
    end)

    install_manifest(config)
  end

  @spec vector_literal([number()]) :: String.t()
  def vector_literal(values) when is_list(values),
    do: "[" <> Enum.map_join(values, ",", &float_literal/1) <> "]"

  defp claim_job do
    Repo.transaction(fn ->
      job =
        Repo.one(
          from(job in SemanticJob,
            where: job.status == "pending" and job.available_at <= ^DateTime.utc_now(),
            order_by: [asc: job.inserted_at, asc: job.id],
            lock: "FOR UPDATE SKIP LOCKED",
            limit: 1
          )
        )

      if job do
        job
        |> SemanticJob.lifecycle_changeset(%{
          status: "running",
          attempts: job.attempts + 1,
          started_at: DateTime.utc_now()
        })
        |> update_or_rollback()
      end
    end)
    |> case do
      {:ok, job} -> job
      {:error, _reason} -> nil
    end
  end

  defp execute_job(job, provider) do
    message = Repo.get(Message, job.message_id)

    cond do
      is_nil(message) or message.status != "complete" -> finish_invalidated(job)
      Canonical.sha256(message.content) != job.content_digest -> finish_invalidated(job)
      true -> call_provider(job, message, provider)
    end
  end

  defp call_provider(job, message, provider) do
    config = %{
      model_id: job.model_id,
      model_version: job.model_version,
      dimensions: job.dimensions
    }

    case provider.embed(message.content, config) do
      {:ok, embedding} when is_list(embedding) and length(embedding) == job.dimensions ->
        persist_embedding(job, message, embedding)

      {:ok, _wrong_shape} ->
        finish_failed(job, "embedding_dimensions_invalid")

      {:error, reason} when is_atom(reason) ->
        finish_failed(job, Atom.to_string(reason))

      _failure ->
        finish_failed(job, "embedding_provider_failed")
    end
  end

  defp persist_embedding(job, message, embedding) do
    Repo.transaction(fn ->
      locked = Repo.get_for_update!(SemanticJob, job.id)
      current_message = Repo.get!(Message, message.id)
      active = active_manifest()

      if locked.status != "running" or is_nil(active) or active.id != locked.manifest_id or
           Canonical.sha256(current_message.content) != locked.content_digest do
        finish_invalidated_locked(locked)
      else
        id = Ecto.UUID.generate()
        vector = vector_literal(embedding)

        _result =
          Repo.query!(
            "INSERT INTO message_semantic_embeddings (id,message_id,conversation_id,manifest_id,generation,model_id,model_version,dimensions,content_digest,status,embedding,inserted_at,updated_at) VALUES ($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,$6,$7,$8,$9,'ready',$10::text::vector,now(),now()) ON CONFLICT (message_id,generation) DO UPDATE SET content_digest=EXCLUDED.content_digest, status='ready', embedding=EXCLUDED.embedding, updated_at=now()",
            [
              id,
              locked.message_id,
              locked.conversation_id,
              locked.manifest_id,
              locked.generation,
              locked.model_id,
              locked.model_version,
              locked.dimensions,
              locked.content_digest,
              vector
            ]
          )

        locked
        |> SemanticJob.lifecycle_changeset(%{
          status: "completed",
          error_code: nil,
          completed_at: DateTime.utc_now()
        })
        |> update_or_rollback()

        :completed
      end
    end)
    |> case do
      {:ok, status} -> {:ok, status}
      {:error, _reason} -> finish_failed(job, "embedding_persist_failed")
    end
  end

  defp finish_failed(job, reason) do
    error_code = reason |> String.replace(~r/[^a-z0-9_]/, "_") |> String.slice(0, 64)

    job
    |> SemanticJob.lifecycle_changeset(%{
      status: "failed",
      error_code: error_code,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()

    {:ok, :failed}
  end

  defp finish_invalidated(job) do
    job
    |> SemanticJob.lifecycle_changeset(%{
      status: "invalidated",
      error_code: "source_stale",
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()

    {:ok, :invalidated}
  end

  defp finish_invalidated_locked(job) do
    job
    |> SemanticJob.lifecycle_changeset(%{
      status: "invalidated",
      error_code: "manifest_or_source_stale",
      completed_at: DateTime.utc_now()
    })
    |> update_or_rollback()

    :invalidated
  end

  defp invalidate_locked(message, action, reason_code) do
    generation = (active_manifest() || %SemanticManifest{generation: 1}).generation
    content_digest = Canonical.sha256(message.content)

    %{num_rows: deleted} =
      Repo.query!("DELETE FROM message_semantic_embeddings WHERE message_id=$1::text::uuid", [
        message.id
      ])

    {invalidated, _rows} =
      Repo.update_all(
        from(job in SemanticJob,
          where:
            job.message_id == ^message.id and
              job.status in ["pending", "running", "completed", "failed"]
        ),
        set: [status: "invalidated", error_code: reason_code, completed_at: DateTime.utc_now()]
      )

    projection = %{
      "message_id" => message.id,
      "conversation_id" => message.conversation_id,
      "content_digest" => content_digest,
      "action" => action,
      "reason_code" => reason_code,
      "generation" => generation,
      "deleted_embedding_count" => deleted,
      "invalidated_job_count" => invalidated
    }

    %SemanticDerivativeReceipt{}
    |> SemanticDerivativeReceipt.changeset(
      Map.put(projection, "receipt_digest", Canonical.digest!(projection))
    )
    |> insert_or_rollback()
  end

  defp backfill!(manifest) do
    _result =
      Repo.query!(
        """
        INSERT INTO semantic_embedding_jobs (
          id,message_id,conversation_id,manifest_id,generation,model_id,model_version,
          dimensions,content_digest,status,attempts,available_at,inserted_at,updated_at
        )
        SELECT gen_random_uuid(),m.id,m.conversation_id,$1::text::uuid,$2,$3,$4,$5,
          encode(digest(m.content,'sha256'),'hex'),'pending',0,now(),now(),now()
        FROM messages m WHERE m.status='complete' AND m.role IN ('user','assistant')
        ON CONFLICT (message_id,generation) DO NOTHING
        """,
        [
          manifest.id,
          manifest.generation,
          manifest.model_id,
          manifest.model_version,
          manifest.dimensions
        ]
      )

    :ok
  end

  defp validate_config(%{model_id: model_id, model_version: model_version, dimensions: 64})
       when is_binary(model_id) and byte_size(model_id) in 1..128 and is_binary(model_version) and
              byte_size(model_version) in 1..128,
       do: :ok

  defp validate_config(_config), do: {:error, :semantic_manifest_invalid}

  defp float_literal(value) when is_number(value) do
    value |> Kernel.*(1.0) |> Float.to_string()
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
