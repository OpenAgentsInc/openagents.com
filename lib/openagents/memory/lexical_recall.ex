defmodule OpenAgents.Memory.LexicalRecall do
  @moduledoc "Deterministic, browser-conversation-scoped PostgreSQL lexical recall."

  import Ecto.Query

  alias OpenAgents.Conversations.{Conversation, Message, Turn}
  alias OpenAgents.Conversations.ToolStep, as: TurnToolStep

  alias OpenAgents.Memory.{
    RecallMatch,
    RecallMessage,
    RecallNeighborhood,
    RecallPage,
    RecallSnapshot
  }

  alias OpenAgents.Repo
  alias OpenAgents.Voice.ResponseReceipt, as: VoiceResponseReceipt
  alias OpenAgents.Voice.Session, as: VoiceSession
  alias OpenAgents.Voice.ToolStep, as: VoiceToolStep

  @maximum_query_bytes 512
  @maximum_results 10
  @default_results 5
  @maximum_excerpt_bytes 800
  @maximum_context_messages 3
  @terminal_tool_statuses ~w(succeeded failed refused cancelled unavailable interrupted)
  # Bound on the result/error text admitted to the lexical tool-step document.
  @maximum_tool_search_characters 2_000
  # Bound on the rendered step context returned by read/4 for a tool-step ref.
  @maximum_tool_context_bytes 4_000
  @tool_step_prefixes %{turn_tool_step: "turn-tool-step", voice_tool_step: "voice-tool-step"}

  @doc false
  def capture_ref(repo, conversation_id, excluded_message_id)
      when is_atom(repo) and is_binary(conversation_id) and is_binary(excluded_message_id) do
    query =
      from(message in Message,
        where:
          message.conversation_id == ^conversation_id and
            message.id != ^excluded_message_id and
            message.role in ["user", "assistant"] and message.status == "complete",
        order_by: [desc: message.inserted_at, desc: message.id],
        limit: 1,
        select: message.id
      )

    case repo.one(query) do
      nil -> {:error, :recall_snapshot_unavailable}
      message_id -> {:ok, "message:#{message_id}"}
    end
  end

  @spec load_snapshot(Conversation.t(), String.t()) ::
          {:ok, RecallSnapshot.t()} | {:error, :invalid_snapshot_ref | :scope_refused}
  def load_snapshot(%Conversation{id: conversation_id}, "message:" <> message_id) do
    with {:ok, parsed_id} <- Ecto.UUID.cast(message_id),
         %Message{} = message <-
           Repo.one(
             from(message in Message,
               where:
                 message.id == ^parsed_id and message.conversation_id == ^conversation_id and
                   message.role in ["user", "assistant"] and message.status == "complete"
             )
           ) do
      {:ok,
       %RecallSnapshot{
         conversation_id: conversation_id,
         message_id: message.id,
         inserted_at: message.inserted_at
       }}
    else
      :error -> {:error, :invalid_snapshot_ref}
      nil -> {:error, :scope_refused}
    end
  end

  def load_snapshot(%Conversation{}, _invalid_ref), do: {:error, :invalid_snapshot_ref}

  @spec search(Conversation.t(), RecallSnapshot.t(), String.t(), keyword()) ::
          {:ok, [RecallMatch.t()]} | {:error, atom()}
  def search(conversation, snapshot, query, options \\ [])

  def search(
        %Conversation{id: conversation_id},
        %RecallSnapshot{conversation_id: conversation_id} = snapshot,
        query,
        options
      ) do
    with {:ok, %RecallPage{matches: matches}} <-
           search_page(
             %Conversation{id: conversation_id},
             snapshot,
             query,
             options
           ) do
      {:ok, matches}
    end
  end

  def search(%Conversation{}, %RecallSnapshot{}, _query, _options),
    do: {:error, :scope_refused}

  def search(%Conversation{}, _snapshot, _query, _options), do: {:error, :invalid_snapshot}

  @spec search_page(Conversation.t(), RecallSnapshot.t(), String.t(), keyword()) ::
          {:ok, RecallPage.t()} | {:error, atom()}
  def search_page(conversation, snapshot, query, options \\ [])

  def search_page(
        %Conversation{id: conversation_id},
        %RecallSnapshot{conversation_id: conversation_id} = snapshot,
        query,
        options
      ) do
    with {:ok, normalized_query} <- normalize_query(query),
         {:ok, result_count} <- result_count(options),
         {:ok, before} <- time_bound(options, :before),
         {:ok, after_time} <- time_bound(options, :after) do
      rows =
        search_rows(
          conversation_id,
          snapshot,
          normalized_query,
          result_count + 1,
          before,
          after_time
        )

      truncated = length(rows) > result_count

      matches =
        rows
        |> Enum.take(result_count)
        |> Enum.with_index(1)
        |> Enum.map(fn {row, rank} -> recall_match(row, rank) end)

      {:ok, %RecallPage{matches: matches, truncated: truncated}}
    end
  end

  def search_page(%Conversation{}, %RecallSnapshot{}, _query, _options),
    do: {:error, :scope_refused}

  def search_page(%Conversation{}, _snapshot, _query, _options),
    do: {:error, :invalid_snapshot}

  @spec read(Conversation.t(), RecallSnapshot.t(), String.t(), keyword()) ::
          {:ok, RecallNeighborhood.t()} | {:error, atom()}
  def read(conversation, snapshot, source_ref, options \\ [])

  def read(
        %Conversation{id: conversation_id},
        %RecallSnapshot{conversation_id: conversation_id} = snapshot,
        "message:" <> message_id,
        options
      ) do
    with {:ok, parsed_id} <- cast_message_id(message_id),
         {:ok, before_count} <- context_count(options, :before),
         {:ok, after_count} <- context_count(options, :after),
         %Message{} = source <- recall_source(conversation_id, snapshot, parsed_id) do
      {before_messages, before_truncated} =
        neighboring_messages(conversation_id, snapshot, source, :before, before_count)

      {after_messages, after_truncated} =
        neighboring_messages(conversation_id, snapshot, source, :after, after_count)

      {:ok,
       %RecallNeighborhood{
         source_ref: "message:#{source.id}",
         messages: Enum.map(before_messages ++ [source] ++ after_messages, &recall_message/1),
         before_truncated: before_truncated,
         after_truncated: after_truncated
       }}
    else
      :error -> {:error, :invalid_source_ref}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def read(
        %Conversation{id: conversation_id},
        %RecallSnapshot{conversation_id: conversation_id} = snapshot,
        "turn-tool-step:" <> step_id,
        options
      ) do
    read_tool_step(conversation_id, snapshot, :turn_tool_step, step_id, options)
  end

  def read(
        %Conversation{id: conversation_id},
        %RecallSnapshot{conversation_id: conversation_id} = snapshot,
        "voice-tool-step:" <> step_id,
        options
      ) do
    read_tool_step(conversation_id, snapshot, :voice_tool_step, step_id, options)
  end

  def read(%Conversation{}, %RecallSnapshot{}, "message:" <> _message_id, _options),
    do: {:error, :scope_refused}

  def read(%Conversation{}, %RecallSnapshot{}, "turn-tool-step:" <> _step_id, _options),
    do: {:error, :scope_refused}

  def read(%Conversation{}, %RecallSnapshot{}, "voice-tool-step:" <> _step_id, _options),
    do: {:error, :scope_refused}

  def read(%Conversation{}, %RecallSnapshot{}, _source_ref, _options),
    do: {:error, :invalid_source_ref}

  def read(%Conversation{}, _snapshot, _source_ref, _options),
    do: {:error, :invalid_snapshot}

  # Resolves one snapshot-admitted tool step into a bounded neighborhood: the
  # step rendered as a labeled tool_activity source plus the nearest admitted
  # conversation messages before/after its completion instant. Foreign and
  # unknown step ids share the messages' single not_found outcome.
  defp read_tool_step(conversation_id, snapshot, kind, step_id, options) do
    with {:ok, parsed_id} <- cast_message_id(step_id),
         {:ok, before_count} <- context_count(options, :before),
         {:ok, after_count} <- context_count(options, :after),
         %{} = step <- tool_step_source(conversation_id, snapshot, kind, parsed_id) do
      anchor = %{inserted_at: step.completed_at, id: step.id}

      {before_messages, before_truncated} =
        neighboring_messages(conversation_id, snapshot, anchor, :before, before_count)

      {after_messages, after_truncated} =
        neighboring_messages(conversation_id, snapshot, anchor, :after, after_count)

      source_ref = tool_step_ref(kind, step.id)

      {:ok,
       %RecallNeighborhood{
         source_ref: source_ref,
         messages:
           Enum.map(before_messages, &recall_message/1) ++
             [tool_step_recall_message(source_ref, step)] ++
             Enum.map(after_messages, &recall_message/1),
         before_truncated: before_truncated,
         after_truncated: after_truncated,
         source_step: tool_step_detail(kind, source_ref, step)
       }}
    else
      :error -> {:error, :invalid_source_ref}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tool_step_source(conversation_id, snapshot, :turn_tool_step, step_id) do
    Repo.one(
      from(step in TurnToolStep,
        join: turn in Turn,
        on: turn.id == step.turn_id,
        left_join: anchor in Message,
        on: anchor.id == turn.assistant_message_id,
        where: step.id == ^step_id and turn.conversation_id == ^conversation_id,
        select: step
      )
      |> admitted_tool_step(snapshot)
    )
  end

  defp tool_step_source(conversation_id, snapshot, :voice_tool_step, step_id) do
    Repo.one(
      from(step in VoiceToolStep,
        join: session in VoiceSession,
        on: session.id == step.voice_session_id,
        left_join: receipt in VoiceResponseReceipt,
        on: receipt.id == step.voice_response_receipt_id,
        left_join: anchor in Message,
        on: anchor.id == receipt.assistant_message_id,
        where: step.id == ^step_id and session.conversation_id == ^conversation_id,
        select: step
      )
      |> admitted_tool_step(snapshot)
    )
  end

  # Same admission fence as search: completed at or before the watermark
  # instant, or anchored by a snapshot-admitted assistant message.
  defp admitted_tool_step(query, snapshot) do
    from([step, ..., anchor] in query,
      where:
        step.status in ^@terminal_tool_statuses and
          not is_nil(step.completed_at) and
          (step.completed_at <= ^snapshot.inserted_at or
             (anchor.status == "complete" and
                (anchor.inserted_at < ^snapshot.inserted_at or
                   (anchor.inserted_at == ^snapshot.inserted_at and
                      anchor.id <= ^snapshot.message_id))))
    )
  end

  defp tool_step_recall_message(source_ref, step) do
    {content, _truncated} = bounded_tool_step_context(step)

    %RecallMessage{
      source_ref: source_ref,
      role: "tool_activity",
      observed_at: step.completed_at,
      content: content
    }
  end

  defp bounded_tool_step_context(step) do
    header =
      "tool #{step.tool_name} #{step.status} " <>
        "(executor: #{step.executor_disclosure}; requested #{iso8601_or_unknown(step.requested_at)}; " <>
        "completed #{iso8601_or_unknown(step.completed_at)})"

    rendered = header <> tool_step_outcome_fragment(step)

    if byte_size(rendered) <= @maximum_tool_context_bytes do
      {rendered, false}
    else
      {bounded_text(rendered, @maximum_tool_context_bytes), true}
    end
  end

  defp tool_step_detail(kind, source_ref, step) do
    {_content, truncated} = bounded_tool_step_context(step)

    %{
      source_ref: source_ref,
      surface: if(kind == :turn_tool_step, do: "text", else: "voice"),
      tool_name: step.tool_name,
      status: step.status,
      argument_digest: step.argument_digest,
      executor_id: step.executor_id,
      executor_disclosure: step.executor_disclosure,
      requested_at: step.requested_at,
      completed_at: step.completed_at,
      result: bounded_optional_json(step.result),
      error: bounded_optional_json(step.error),
      truncated: truncated
    }
  end

  defp bounded_optional_json(nil), do: nil

  defp bounded_optional_json(value) when is_map(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> bounded_text(encoded, @maximum_tool_context_bytes)
      {:error, _reason} -> nil
    end
  end

  defp iso8601_or_unknown(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601_or_unknown(_value), do: "unknown"

  defp bounded_text(content, maximum_bytes) do
    content
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, accumulated ->
      if byte_size(accumulated) + byte_size(grapheme) <= maximum_bytes,
        do: {:cont, accumulated <> grapheme},
        else: {:halt, accumulated}
    end)
  end

  # The merged lexical source universe: complete user/assistant messages plus
  # terminal durable tool steps from both surfaces, each fetched under the same
  # immutable snapshot fence, then merged deterministically by score with
  # timestamp/id ties.
  defp search_rows(conversation_id, snapshot, query, result_count, before, after_time) do
    (message_rows(conversation_id, snapshot, query, result_count, before, after_time) ++
       turn_tool_step_rows(conversation_id, snapshot, query, result_count, before, after_time) ++
       voice_tool_step_rows(conversation_id, snapshot, query, result_count, before, after_time))
    |> Enum.sort_by(
      &{-&1.score * 1.0, -DateTime.to_unix(&1.observed_at, :microsecond),
       descending_identity(&1.id)}
    )
    |> Enum.take(result_count)
  end

  defp message_rows(conversation_id, snapshot, query, result_count, before, after_time) do
    base_query =
      from(message in Message,
        where:
          message.conversation_id == ^conversation_id and
            message.role in ["user", "assistant"] and message.status == "complete" and
            (message.inserted_at < ^snapshot.inserted_at or
               (message.inserted_at == ^snapshot.inserted_at and
                  message.id <= ^snapshot.message_id)) and
            fragment("? @@ websearch_to_tsquery('simple', ?)", message.search_vector, ^query),
        order_by: [
          desc:
            fragment(
              "ts_rank_cd(?, websearch_to_tsquery('simple', ?), 32)",
              message.search_vector,
              ^query
            ),
          desc: message.inserted_at,
          desc: message.id
        ],
        limit: ^result_count,
        select: %{
          id: message.id,
          role: message.role,
          content: message.content,
          observed_at: message.inserted_at,
          score:
            fragment(
              "ts_rank_cd(?, websearch_to_tsquery('simple', ?), 32)",
              message.search_vector,
              ^query
            )
        }
      )

    base_query
    |> maybe_before(before)
    |> maybe_after(after_time)
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :kind, :message))
  end

  defmacrop tool_step_document(step) do
    quote do
      fragment(
        "to_tsvector('simple', ? || ' ' || ? || ' ' || left(coalesce(?::text, '') || ' ' || coalesce(?::text, ''), ?))",
        unquote(step).tool_name,
        unquote(step).status,
        unquote(step).result,
        unquote(step).error,
        ^@maximum_tool_search_characters
      )
    end
  end

  defmacrop tool_step_match(step, query) do
    quote do
      fragment(
        "? @@ websearch_to_tsquery('simple', ?)",
        tool_step_document(unquote(step)),
        unquote(query)
      )
    end
  end

  defmacrop tool_step_rank(step, query) do
    quote do
      fragment(
        "ts_rank_cd(?, websearch_to_tsquery('simple', ?), 32)",
        tool_step_document(unquote(step)),
        unquote(query)
      )
    end
  end

  # A tool step is observable at a snapshot only when it completed at or before
  # the watermark message's insertion instant, or when the assistant message
  # that concluded its work unit (turn / voice response) is itself admitted by
  # the message fence. Both predicates compare immutable persisted values with
  # the immutable snapshot, so later work never enters a frozen recall view.
  defp turn_tool_step_rows(conversation_id, snapshot, query, result_count, before, after_time) do
    from(step in TurnToolStep,
      join: turn in Turn,
      on: turn.id == step.turn_id,
      left_join: anchor in Message,
      on: anchor.id == turn.assistant_message_id,
      where: turn.conversation_id == ^conversation_id,
      order_by: [
        desc: tool_step_rank(step, ^query),
        desc: step.completed_at,
        desc: step.id
      ],
      limit: ^result_count,
      select: %{
        id: step.id,
        tool_name: step.tool_name,
        status: step.status,
        result: step.result,
        error: step.error,
        observed_at: step.completed_at,
        score: tool_step_rank(step, ^query)
      }
    )
    |> tool_step_admission(snapshot, query, before, after_time)
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :kind, :turn_tool_step))
  end

  defp voice_tool_step_rows(conversation_id, snapshot, query, result_count, before, after_time) do
    from(step in VoiceToolStep,
      join: session in VoiceSession,
      on: session.id == step.voice_session_id,
      left_join: receipt in VoiceResponseReceipt,
      on: receipt.id == step.voice_response_receipt_id,
      left_join: anchor in Message,
      on: anchor.id == receipt.assistant_message_id,
      where: session.conversation_id == ^conversation_id,
      order_by: [
        desc: tool_step_rank(step, ^query),
        desc: step.completed_at,
        desc: step.id
      ],
      limit: ^result_count,
      select: %{
        id: step.id,
        tool_name: step.tool_name,
        status: step.status,
        result: step.result,
        error: step.error,
        observed_at: step.completed_at,
        score: tool_step_rank(step, ^query)
      }
    )
    |> tool_step_admission(snapshot, query, before, after_time)
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :kind, :voice_tool_step))
  end

  # Shared terminal/fence/match predicates for both step queries. Binding
  # positions: 0 = step, and the last named binding `anchor` is the admitted
  # assistant message anchoring the step's work unit.
  defp tool_step_admission(query, snapshot, search_query, before, after_time) do
    query =
      from([step, ..., anchor] in query,
        where:
          step.status in ^@terminal_tool_statuses and
            not is_nil(step.completed_at) and
            (step.completed_at <= ^snapshot.inserted_at or
               (anchor.status == "complete" and
                  (anchor.inserted_at < ^snapshot.inserted_at or
                     (anchor.inserted_at == ^snapshot.inserted_at and
                        anchor.id <= ^snapshot.message_id)))) and
            tool_step_match(step, ^search_query)
      )

    query
    |> maybe_step_before(before)
    |> maybe_step_after(after_time)
  end

  defp maybe_before(query, nil), do: query

  defp maybe_before(query, before) do
    from(message in query, where: message.inserted_at < ^before)
  end

  defp maybe_after(query, nil), do: query

  defp maybe_after(query, after_time) do
    from(message in query, where: message.inserted_at > ^after_time)
  end

  defp maybe_step_before(query, nil), do: query

  defp maybe_step_before(query, before) do
    from([step] in query, where: step.completed_at < ^before)
  end

  defp maybe_step_after(query, nil), do: query

  defp maybe_step_after(query, after_time) do
    from([step] in query, where: step.completed_at > ^after_time)
  end

  defp descending_identity(id), do: id |> String.to_charlist() |> Enum.map(&(-&1))

  defp recall_source(conversation_id, snapshot, message_id) do
    Repo.one(
      from(message in Message,
        where:
          message.id == ^message_id and message.conversation_id == ^conversation_id and
            message.role in ["user", "assistant"] and message.status == "complete" and
            (message.inserted_at < ^snapshot.inserted_at or
               (message.inserted_at == ^snapshot.inserted_at and
                  message.id <= ^snapshot.message_id))
      )
    )
  end

  defp neighboring_messages(_conversation_id, _snapshot, _source, _direction, 0),
    do: {[], false}

  defp neighboring_messages(conversation_id, snapshot, source, :before, count) do
    rows =
      Repo.all(
        from(message in Message,
          where:
            message.conversation_id == ^conversation_id and
              message.role in ["user", "assistant"] and message.status == "complete" and
              (message.inserted_at < ^source.inserted_at or
                 (message.inserted_at == ^source.inserted_at and message.id < ^source.id)) and
              (message.inserted_at < ^snapshot.inserted_at or
                 (message.inserted_at == ^snapshot.inserted_at and
                    message.id <= ^snapshot.message_id)),
          order_by: [desc: message.inserted_at, desc: message.id],
          limit: ^(count + 1)
        )
      )

    {rows |> Enum.take(count) |> Enum.reverse(), length(rows) > count}
  end

  defp neighboring_messages(conversation_id, snapshot, source, :after, count) do
    rows =
      Repo.all(
        from(message in Message,
          where:
            message.conversation_id == ^conversation_id and
              message.role in ["user", "assistant"] and message.status == "complete" and
              (message.inserted_at > ^source.inserted_at or
                 (message.inserted_at == ^source.inserted_at and message.id > ^source.id)) and
              (message.inserted_at < ^snapshot.inserted_at or
                 (message.inserted_at == ^snapshot.inserted_at and
                    message.id <= ^snapshot.message_id)),
          order_by: [asc: message.inserted_at, asc: message.id],
          limit: ^(count + 1)
        )
      )

    {Enum.take(rows, count), length(rows) > count}
  end

  defp recall_match(%{kind: :message} = row, rank) do
    {excerpt, truncated} = bounded_excerpt(row.content)

    %RecallMatch{
      source_ref: "message:#{row.id}",
      role: row.role,
      observed_at: row.observed_at,
      excerpt: excerpt,
      score: row.score,
      rank: rank,
      truncated: truncated
    }
  end

  defp recall_match(%{kind: kind} = row, rank)
       when kind in [:turn_tool_step, :voice_tool_step] do
    {excerpt, truncated} = row |> tool_step_summary() |> bounded_excerpt()

    %RecallMatch{
      source_ref: tool_step_ref(kind, row.id),
      role: "tool_activity",
      observed_at: row.observed_at,
      excerpt: excerpt,
      score: row.score,
      rank: rank,
      truncated: truncated
    }
  end

  defp tool_step_ref(kind, id), do: "#{Map.fetch!(@tool_step_prefixes, kind)}:#{id}"

  defp tool_step_summary(step) do
    "tool #{step.tool_name} #{step.status}#{tool_step_outcome_fragment(step)}"
  end

  defp tool_step_outcome_fragment(%{status: "succeeded", result: result}) when is_map(result) do
    encoded_json_fragment(result)
  end

  defp tool_step_outcome_fragment(%{error: error}) when is_map(error) do
    encoded_json_fragment(error)
  end

  defp tool_step_outcome_fragment(_step), do: ""

  defp encoded_json_fragment(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> ": #{encoded}"
      {:error, _reason} -> ""
    end
  end

  defp normalize_query(query) when is_binary(query) do
    normalized = String.trim(query)

    if byte_size(normalized) in 1..@maximum_query_bytes,
      do: {:ok, normalized},
      else: {:error, :invalid_recall_query}
  end

  defp normalize_query(_query), do: {:error, :invalid_recall_query}

  defp result_count(options) when is_list(options) do
    count = Keyword.get(options, :first, @default_results)

    if is_integer(count) and count in 1..@maximum_results,
      do: {:ok, count},
      else: {:error, :invalid_result_limit}
  end

  defp result_count(_options), do: {:error, :invalid_result_limit}

  defp time_bound(options, key) do
    case Keyword.get(options, key) do
      nil -> {:ok, nil}
      %DateTime{} = value -> {:ok, value}
      _invalid -> {:error, :invalid_time_bound}
    end
  end

  defp context_count(options, key) when is_list(options) do
    count = Keyword.get(options, key, 2)

    if is_integer(count) and count in 0..@maximum_context_messages,
      do: {:ok, count},
      else: {:error, :invalid_context_limit}
  end

  defp context_count(_options, _key), do: {:error, :invalid_context_limit}

  defp cast_message_id(message_id) do
    case Ecto.UUID.cast(message_id) do
      {:ok, parsed_id} -> {:ok, parsed_id}
      :error -> :error
    end
  end

  defp recall_message(message) do
    %RecallMessage{
      source_ref: "message:#{message.id}",
      role: message.role,
      observed_at: message.inserted_at,
      content: message.content
    }
  end

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
