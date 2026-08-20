defmodule OpenAgents.Memory.HybridRecall do
  @moduledoc "Deterministic scoped lexical/pgvector RRF with lexical fallback."

  alias OpenAgents.Conversations.Conversation
  alias OpenAgents.Memory.{LexicalRecall, RecallMatch, RecallPage, RecallSnapshot, SemanticIndex}
  alias OpenAgents.Repo

  @rrf_constant 60
  @lexical_weight 65
  @semantic_weight 35
  @maximum_excerpt_bytes 800

  defdelegate capture_ref(repo, conversation_id, excluded_message_id), to: LexicalRecall
  defdelegate load_snapshot(conversation, reference), to: LexicalRecall
  defdelegate read(conversation, snapshot, source_ref, options), to: LexicalRecall

  def read(conversation, snapshot, source_ref),
    do: LexicalRecall.read(conversation, snapshot, source_ref, [])

  def search(conversation, snapshot, query, options \\ []) do
    with {:ok, page} <- search_page(conversation, snapshot, query, options),
         do: {:ok, page.matches}
  end

  def search_page(conversation, snapshot, query, options \\ [])

  def search_page(
        %Conversation{id: conversation_id} = conversation,
        %RecallSnapshot{conversation_id: conversation_id} = snapshot,
        query,
        options
      ) do
    with {:ok, lexical} <- LexicalRecall.search_page(conversation, snapshot, query, options) do
      semantic_or_fallback(lexical, conversation, snapshot, query, options)
    end
  end

  def search_page(%Conversation{}, %RecallSnapshot{}, _query, _options),
    do: {:error, :scope_refused}

  defp semantic_or_fallback(lexical, conversation, snapshot, query, options) do
    config = Application.fetch_env!(:openagents, :semantic_index)
    provider = Keyword.fetch!(config, :provider)

    with manifest when not is_nil(manifest) <- SemanticIndex.active_manifest(),
         true <- SemanticIndex.generation_ready?(conversation.id, manifest.generation),
         {:ok, embedding} <-
           provider.embed(query, Map.take(manifest, [:model_id, :model_version, :dimensions])),
         true <- length(embedding) == manifest.dimensions,
         {:ok, semantic_rows} <-
           semantic_rows(conversation, snapshot, manifest, embedding, options) do
      {:ok, merge(lexical, semantic_rows, Keyword.get(options, :first, 5))}
    else
      nil -> {:ok, degraded(lexical, "semantic_manifest_unavailable")}
      false -> {:ok, degraded(lexical, "semantic_index_incomplete")}
      {:error, reason} -> {:ok, degraded(lexical, bounded_reason(reason))}
    end
  end

  defp semantic_rows(conversation, snapshot, manifest, embedding, options) do
    limit = min(max(Keyword.get(options, :first, 5) * 2, 2), 20)
    vector = SemanticIndex.vector_literal(embedding)

    result =
      Repo.query(
        """
        SELECT m.id::text,m.role,m.content,m.inserted_at,1-(e.embedding <=> $1::text::vector) AS score
        FROM message_semantic_embeddings e
        JOIN messages m ON m.id=e.message_id
        WHERE e.conversation_id=$2::text::uuid AND m.conversation_id=$2::text::uuid
          AND e.manifest_id=$3::text::uuid AND e.generation=$4
          AND e.model_id=$5 AND e.model_version=$6
          AND e.status='ready'
          AND e.content_digest=encode(digest(m.content,'sha256'),'hex')
          AND m.status='complete' AND m.role IN ('user','assistant')
          AND 1-(e.embedding <=> $1::text::vector) >= 0.20
          AND (m.inserted_at < $7 OR (m.inserted_at=$7 AND m.id <= $8::text::uuid))
        ORDER BY e.embedding <=> $1::text::vector ASC,m.inserted_at DESC,m.id DESC
        LIMIT $9
        """,
        [
          vector,
          conversation.id,
          manifest.id,
          manifest.generation,
          manifest.model_id,
          manifest.model_version,
          snapshot.inserted_at,
          snapshot.message_id,
          limit
        ]
      )

    case result do
      {:ok, %{rows: rows}} ->
        {:ok,
         rows
         |> Enum.with_index(1)
         |> Enum.map(fn {[id, role, content, observed_at, score], rank} ->
           %{
             id: id,
             role: role,
             content: content,
             observed_at: utc_datetime(observed_at),
             semantic_score: score,
             semantic_rank: rank
           }
         end)}

      {:error, _reason} ->
        {:error, :semantic_query_failed}
    end
  end

  defp merge(lexical, semantic_rows, first) do
    # Keyed by full typed source ref so non-message lexical sources (durable
    # tool steps) fuse deterministically without ref corruption; semantic
    # candidates exist only for messages.
    lexical_by_ref = Map.new(lexical.matches, &{&1.source_ref, &1})
    semantic_by_ref = Map.new(semantic_rows, &{"message:#{&1.id}", &1})
    refs = (Map.keys(lexical_by_ref) ++ Map.keys(semantic_by_ref)) |> Enum.uniq()

    ranked =
      refs
      |> Enum.map(fn ref -> merged_candidate(ref, lexical_by_ref[ref], semantic_by_ref[ref]) end)
      |> Enum.sort_by(&{-&1.score, -unix_microsecond(&1.observed_at), descending_uuid(&1.ref)})

    matches =
      ranked
      |> Enum.take(first)
      |> Enum.with_index(1)
      |> Enum.map(fn {candidate, rank} ->
        %RecallMatch{
          source_ref: candidate.ref,
          role: candidate.role,
          observed_at: candidate.observed_at,
          excerpt: candidate.excerpt,
          score: candidate.score,
          rank: rank,
          truncated: candidate.truncated
        }
      end)

    %RecallPage{
      matches: matches,
      truncated: lexical.truncated or length(ranked) > first,
      strategy: "hybrid_rrf",
      semantic_degraded: false,
      semantic_reason: nil
    }
  end

  defp merged_candidate(ref, lexical, semantic) do
    lexical_score = if lexical, do: @lexical_weight / (@rrf_constant + lexical.rank), else: 0.0

    semantic_score =
      if semantic, do: @semantic_weight / (@rrf_constant + semantic.semantic_rank), else: 0.0

    {excerpt, truncated} =
      if lexical,
        do: {lexical.excerpt, lexical.truncated},
        else: bounded_excerpt(semantic.content)

    %{
      ref: ref,
      role: if(lexical, do: lexical.role, else: semantic.role),
      observed_at: if(lexical, do: lexical.observed_at, else: semantic.observed_at),
      excerpt: excerpt,
      truncated: truncated,
      score: lexical_score + semantic_score
    }
  end

  defp degraded(page, reason),
    do: %{page | strategy: "lexical_fallback", semantic_degraded: true, semantic_reason: reason}

  defp bounded_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> bounded_reason()

  defp bounded_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 64)
  defp bounded_reason(_reason), do: "semantic_unavailable"

  defp descending_uuid(id), do: id |> String.to_charlist() |> Enum.map(&(-&1))

  defp unix_microsecond(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp unix_microsecond(%NaiveDateTime{} = value) do
    NaiveDateTime.diff(value, ~N[1970-01-01 00:00:00], :microsecond)
  end

  defp utc_datetime(%DateTime{} = value), do: value
  defp utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp bounded_excerpt(content) when byte_size(content) <= @maximum_excerpt_bytes,
    do: {content, false}

  defp bounded_excerpt(content) do
    excerpt =
      content
      |> String.graphemes()
      |> Enum.reduce_while("", fn grapheme, accumulated ->
        if byte_size(accumulated) + byte_size(grapheme) <= @maximum_excerpt_bytes,
          do: {:cont, accumulated <> grapheme},
          else: {:halt, accumulated}
      end)

    {excerpt, true}
  end
end
