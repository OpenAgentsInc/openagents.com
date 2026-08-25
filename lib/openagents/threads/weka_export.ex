defmodule OpenAgents.Threads.WekaExport do
  @moduledoc """
  Exports consenting thread transcripts as WEKA v1 traces, and a recorded set
  of them as a corpus (issue #218).

  WEKA is the trace format AgentX replays under AIPerf
  (`docs/2026-08-24-benchmark-workbench-agentx.md`, section 5). A trace is a
  session: an ordered list of model calls, each carrying the wall-clock offset
  it happened at, how long the call took, how many tokens went in and came
  out, and the identity of the 64-token blocks its prompt was made of. Content
  never appears. What survives is the shape of the traffic — multi-turn
  accumulation, context growth, prefix reuse, and sub-agent bursts — which is
  the thing a serving stack is measured against.

  ## What a request is

  The transcript vocabulary is `turn.user`, `turn.reasoning`, `tool.ran`,
  `turn.assistant` (`docs/2026-08-24-coder-account-integration-audit.md`). One
  model call produces a run of model-authored events that ends either at a tool
  call or at an answer, so a request closes at each `tool.*` and each
  `turn.assistant`. Its prompt is everything recorded before that run began;
  its output is the run. Anything else — the user's turn, the thread's own
  lifecycle records — accumulates into the context the next call carries.

  Because a call's prompt is a prefix of the next call's prompt, the block ids
  of one request are a prefix of the next request's. That is not asserted here;
  it falls out of how contexts grow, which is exactly why the measurement in
  `prefix_reuse/1` says something about the source session.

  ## How blocks are anonymized

  A prompt is cut into 64-token blocks and each block is replaced by a
  session-scoped chained hash: `sha256(previous_hash <> block_text)`, seeded
  from a salt derived from the thread id and the caller's salt. The chain is
  load-bearing rather than decorative. A block of text that appears twice in
  one context at different positions is not cache-equivalent — only a matching
  *prefix* hits a warm KV cache — and chaining is what tells the two apart.
  The salt makes block identity session-scoped, so nothing can be matched
  across sessions or attacked with a dictionary of likely blocks.

  The emitted ids are then remapped to session-local integers in first-seen
  order, `hash_id_scope: "local"`, which is what the reference converter
  publishes and what the replayer consumes. Only whole blocks are hashed: the
  trailing partial block is dropped and `in` counts the tokens actually
  covered, so a replayed prompt is exactly what was hashed and nothing more. A
  prompt with no whole block reports its true token count instead, the same
  fallback the reference converter uses when no hash coverage exists.

  Tokens here are whitespace-separated words, not a model's byte-pair tokens.
  The measure that matters is block *structure* — which blocks repeat, and
  where — and that is preserved under any consistent tokenizer.

  ## Consent

  Export is gated by the thread's visibility tier (THREAD-002). A `dark`
  thread refuses with `:consent_required` and contributes nothing: not a
  request, not a block count, not a token. The gate applies to sub-agents
  independently, because a consenting parent may spawn a narrower child
  (THREAD-003) — a `dark` child produces no sub-agent entry and no trace of
  having existed. `corpus/2` records every refusal by thread id and reason, so
  a corpus is honest about what it does not contain.

  Publication of a corpus is a separate, explicit decision. This module builds
  documents; nothing here publishes one.
  """

  import Ecto.Query

  alias OpenAgents.BuildInfo
  alias OpenAgents.Repo
  alias OpenAgents.Threads.Event
  alias OpenAgents.Threads.Thread

  @block_size 64
  @hash_id_scope "local"
  @corpus_format "openagents-weka-corpus-v1"
  @subagent_type "child_thread"

  @typedoc "A WEKA v1 trace document."
  @type trace :: %{String.t() => term()}

  @typedoc "A corpus of WEKA v1 traces with the set and revision that built it."
  @type corpus :: %{String.t() => term()}

  @doc "The KV-cache block size the WEKA format is defined against."
  @spec block_size() :: pos_integer()
  def block_size, do: @block_size

  @doc """
  Exports one consenting thread as a WEKA v1 trace.

  Accepts a `Thread` struct or a thread id. Options:

    * `:salt` — caller-supplied salt folded into the session's block identity.
      Defaults to `""`. It changes nothing an exported document shows, because
      ids are remapped session-locally; it changes what the hashes behind them
      are, which is what keeps block identity from being guessable.

  Returns `{:error, :consent_required}` for a thread its owner left `dark`,
  and `{:error, :thread_not_found}` for an id that resolves to nothing.
  """
  @spec export(Thread.t() | String.t(), keyword()) ::
          {:ok, trace()} | {:error, :consent_required | :thread_not_found}
  def export(thread_or_id, options \\ [])

  def export(%Thread{} = thread, options) when is_list(options), do: gate(thread, options)

  def export(thread_id, options) when is_binary(thread_id) and is_list(options) do
    with {:ok, id} <- Ecto.UUID.cast(thread_id),
         %Thread{} = thread <- Repo.get(Thread, id) do
      gate(thread, options)
    else
      _unresolved -> {:error, :thread_not_found}
    end
  end

  @doc """
  Builds a corpus from a recorded set of thread ids.

  The document records the ids it was asked for, the ids it included, every
  refusal with its reason, and the code revision that built it, so the same set
  and the same revision rebuild the same corpus. Options are `:salt` (see
  `export/2`) and `:revision`, which defaults to this build's own.
  """
  @spec corpus([String.t()], keyword()) :: {:ok, corpus()}
  def corpus(thread_ids, options \\ []) when is_list(thread_ids) do
    requested = Enum.map(thread_ids, &to_string/1)
    salt = Keyword.get(options, :salt, "")
    revision = Keyword.get(options, :revision, build_revision())

    {traces, refused} =
      Enum.reduce(requested, {[], []}, fn thread_id, {traces, refused} ->
        case export(thread_id, salt: salt) do
          {:ok, trace} ->
            {[trace | traces], refused}

          {:error, reason} ->
            {traces, [%{"thread_id" => thread_id, "reason" => to_string(reason)} | refused]}
        end
      end)

    traces = Enum.reverse(traces)

    {:ok,
     %{
       "format" => @corpus_format,
       "block_size" => @block_size,
       "hash_id_scope" => @hash_id_scope,
       "code_revision" => revision,
       "salt_digest" => digest(salt),
       "requested_thread_ids" => requested,
       "included_thread_ids" => Enum.map(traces, & &1["id"]),
       "refused" => Enum.reverse(refused),
       "traces" => traces,
       "prefix_reuse" => prefix_reuse(%{"traces" => traces})
     }}
  end

  @doc """
  Measures prefix reuse over an exported trace or corpus.

  For each agent — the main thread and each sub-agent entry — every call after
  the agent's first contributes the number of leading blocks it shares with the
  call before it. `rate` is those reused blocks over all blocks, which is the
  KV-cache hit rate a replay of this traffic would see with a perfect cache.

  The number is computed from the anonymized block ids, and it is the same
  number the raw transcript gives, because the ids carry the source's block
  structure. `test/openagents/threads/weka_export_test.exs` computes both and
  holds them equal.
  """
  @spec prefix_reuse(trace() | corpus()) :: %{String.t() => number()}
  def prefix_reuse(%{"traces" => traces}) when is_list(traces) do
    traces
    |> Enum.flat_map(&agent_sequences/1)
    |> tally()
  end

  def prefix_reuse(%{"requests" => _requests} = trace) do
    trace |> agent_sequences() |> tally()
  end

  # ── the consent gate ───────────────────────────────────────────────────────

  defp gate(%Thread{} = thread, options) do
    if Thread.wide?(thread) do
      {:ok, build(thread, options)}
    else
      {:error, :consent_required}
    end
  end

  # ── the trace ──────────────────────────────────────────────────────────────

  defp build(%Thread{} = thread, options) do
    salt = Keyword.get(options, :salt, "")
    hashes = %{salt: session_salt(thread, salt), assigned: %{}, next: 0}
    events = load_events(thread.id)
    origin = origin(thread, events)

    {entries, _hashes} =
      walk(events,
        hashes: hashes,
        model: thread.model,
        children: load_consenting_children(thread.id),
        origin: origin,
        call_start: origin
      )

    %{
      "id" => thread.id,
      "models" => models(thread, entries),
      "block_size" => @block_size,
      "hash_id_scope" => @hash_id_scope,
      "requests" => entries
    }
  end

  defp models(%Thread{model: model}, entries) do
    entries
    |> Enum.flat_map(&Map.get(&1, "models", []))
    |> List.insert_at(0, model)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # One agent's events become one list of entries. The parent walks with the
  # spawn children it may expand; a sub-agent walks with none, because the WEKA
  # format nests one level and a grandchild's spawn is only context.
  defp walk(events, options) do
    accumulator = %{
      context: new_context(Keyword.fetch!(options, :hashes).salt),
      hashes: Keyword.fetch!(options, :hashes),
      model: Keyword.fetch!(options, :model),
      children: Keyword.get(options, :children, %{}),
      origin: Keyword.fetch!(options, :origin),
      call_start: Keyword.fetch!(options, :call_start),
      previous_end: nil,
      entries: [],
      run: []
    }

    final = Enum.reduce(events, accumulator, &step/2)
    {Enum.reverse(final.entries), final.hashes}
  end

  defp step(%Event{} = event, accumulator) do
    tokens = tokenize(extract_text(event.payload))

    cond do
      terminating?(event.event_type) -> close_request(accumulator, event, tokens)
      model_authored?(event.event_type) -> %{accumulator | run: accumulator.run ++ tokens}
      true -> absorb_input(accumulator, event, tokens)
    end
  end

  defp absorb_input(accumulator, %Event{} = event, tokens) do
    {context, hashes} =
      absorb(accumulator.context, tokens, accumulator.hashes)

    accumulator
    |> maybe_subagent(event)
    |> Map.merge(%{context: context, hashes: hashes, call_start: event.emitted_at})
  end

  defp close_request(accumulator, %Event{} = event, tokens) do
    run = accumulator.run ++ tokens
    {ids, input_tokens} = prompt(accumulator.context)
    call_start = accumulator.call_start

    request =
      %{
        "t" => elapsed(accumulator.origin, call_start),
        "type" => "n",
        "model" => accumulator.model,
        "in" => input_tokens,
        "out" => length(run),
        "hash_ids" => ids,
        "api_time" => elapsed(call_start, event.emitted_at)
      }
      |> put_think_time(accumulator.previous_end, call_start)

    {context, hashes} = absorb(accumulator.context, run, accumulator.hashes)

    %{
      accumulator
      | entries: [request | accumulator.entries],
        context: context,
        hashes: hashes,
        run: [],
        call_start: event.emitted_at,
        previous_end: event.emitted_at
    }
  end

  defp put_think_time(request, nil, _call_start), do: request

  defp put_think_time(request, previous_end, call_start) do
    Map.put(request, "think_time", elapsed(previous_end, call_start))
  end

  # ── sub-agents ─────────────────────────────────────────────────────────────

  defp maybe_subagent(accumulator, %Event{event_type: "thread.spawn", payload: payload}) do
    with child_id when is_binary(child_id) <- spawned_id(payload),
         %{thread: child, events: events} <- Map.get(accumulator.children, child_id) do
      {inner, hashes} =
        walk(events,
          hashes: accumulator.hashes,
          model: child.model,
          origin: accumulator.origin,
          call_start: child.started_at || accumulator.call_start
        )

      case inner do
        [] -> %{accumulator | hashes: hashes}
        requests -> add_subagent(accumulator, hashes, child, events, requests)
      end
    else
      _absent -> accumulator
    end
  end

  defp maybe_subagent(accumulator, %Event{}), do: accumulator

  defp add_subagent(accumulator, hashes, %Thread{} = child, events, requests) do
    first = List.first(requests)
    last = List.last(requests)
    finished = last["t"] + last["api_time"]

    entry = %{
      "t" => first["t"],
      "type" => "subagent",
      "agent_id" => "thread_" <> child.id,
      "subagent_type" => @subagent_type,
      "duration_ms" => round(max(finished - first["t"], 0.0) * 1000),
      "total_tokens" => Enum.reduce(requests, 0, &(&2 + &1["in"] + &1["out"])),
      "tool_use_count" => Enum.count(events, &String.starts_with?(&1.event_type, "tool.")),
      "status" => subagent_status(child.status),
      "requests" => requests,
      "models" => child.model |> List.wrap() |> Enum.sort()
    }

    %{accumulator | entries: [entry | accumulator.entries], hashes: hashes}
  end

  # The reference converter writes "completed" because its source has no other
  # word. Ours does: a thread that is still open did not complete, and saying
  # so costs nothing.
  defp subagent_status("succeeded"), do: "completed"
  defp subagent_status("open"), do: "running"
  defp subagent_status(status) when is_binary(status), do: status
  defp subagent_status(_status), do: "running"

  defp spawned_id(payload) when is_map(payload) do
    case payload["child_thread_id"] do
      id when is_binary(id) -> id
      _other -> nil
    end
  end

  defp spawned_id(_payload), do: nil

  # ── the block chain ────────────────────────────────────────────────────────

  defp new_context(salt), do: %{ids: [], chain: salt, tail: [], seen: 0}

  defp absorb(context, tokens, hashes) do
    commit(
      %{context | tail: context.tail ++ tokens, seen: context.seen + length(tokens)},
      hashes
    )
  end

  defp commit(%{tail: tail} = context, hashes) when length(tail) >= @block_size do
    {block, rest} = Enum.split(tail, @block_size)
    chain = :crypto.hash(:sha256, context.chain <> "\n" <> Enum.join(block, " "))
    {id, hashes} = intern(hashes, Base.encode16(chain, case: :lower))
    commit(%{context | tail: rest, chain: chain, ids: [id | context.ids]}, hashes)
  end

  defp commit(context, hashes), do: {context, hashes}

  defp intern(%{assigned: assigned, next: next} = hashes, hash) do
    case Map.fetch(assigned, hash) do
      {:ok, id} -> {id, hashes}
      :error -> {next, %{hashes | assigned: Map.put(assigned, hash, next), next: next + 1}}
    end
  end

  # Whole blocks only, the way the reference converter emits them: the replayed
  # prompt is exactly what was hashed. A prompt with no whole block has no hash
  # coverage at all, so it reports its true token count instead of zero.
  defp prompt(%{ids: []} = context), do: {[], context.seen}

  defp prompt(context) do
    ids = Enum.reverse(context.ids)
    {ids, length(ids) * @block_size}
  end

  defp session_salt(%Thread{id: thread_id}, salt) do
    :crypto.hash(:sha256, thread_id <> "\n" <> salt)
  end

  defp digest(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  # ── the measurement ────────────────────────────────────────────────────────

  defp agent_sequences(%{"requests" => requests}) do
    main = requests |> Enum.reject(&(&1["type"] == "subagent")) |> Enum.map(& &1["hash_ids"])

    inner =
      requests
      |> Enum.filter(&(&1["type"] == "subagent"))
      |> Enum.map(fn entry -> Enum.map(entry["requests"], & &1["hash_ids"]) end)

    Enum.reject([main | inner], &(&1 == []))
  end

  defp tally(sequences) do
    {requests, blocks, reused} =
      Enum.reduce(sequences, {0, 0, 0}, fn sequence, {requests, blocks, reused} ->
        {sequence_blocks, sequence_reused} = sequence_reuse(sequence)
        {requests + length(sequence), blocks + sequence_blocks, reused + sequence_reused}
      end)

    %{
      "requests" => requests,
      "blocks" => blocks,
      "reused_blocks" => reused,
      "rate" => if(blocks == 0, do: 0.0, else: reused / blocks)
    }
  end

  defp sequence_reuse(sequence) do
    sequence
    |> Enum.reduce({0, 0, nil}, fn ids, {blocks, reused, previous} ->
      shared = if previous, do: common_prefix(previous, ids), else: 0
      {blocks + length(ids), reused + shared, ids}
    end)
    |> then(fn {blocks, reused, _previous} -> {blocks, reused} end)
  end

  defp common_prefix(earlier, later) do
    earlier |> Enum.zip(later) |> Enum.take_while(fn {a, b} -> a == b end) |> length()
  end

  # ── the transcript ─────────────────────────────────────────────────────────

  defp load_events(thread_id) do
    Repo.all(
      from(event in Event, where: event.thread_id == ^thread_id, order_by: [asc: event.id])
    )
  end

  defp load_consenting_children(thread_id) do
    wide = Thread.wide_visibilities()

    children =
      Repo.all(
        from(thread in Thread,
          where: thread.parent_thread_id == ^thread_id and thread.visibility in ^wide,
          order_by: [asc: thread.inserted_at]
        )
      )

    grouped =
      children
      |> Enum.map(& &1.id)
      |> child_events()
      |> Enum.group_by(& &1.thread_id)

    Map.new(children, fn child ->
      {child.id, %{thread: child, events: Map.get(grouped, child.id, [])}}
    end)
  end

  defp child_events([]), do: []

  defp child_events(ids) do
    Repo.all(from(event in Event, where: event.thread_id in ^ids, order_by: [asc: event.id]))
  end

  defp origin(%Thread{started_at: %DateTime{} = started_at}, _events), do: started_at
  defp origin(%Thread{}, [%Event{emitted_at: emitted_at} | _rest]), do: emitted_at
  defp origin(%Thread{inserted_at: inserted_at}, []), do: inserted_at

  defp elapsed(from, to) do
    max(DateTime.diff(to, from, :microsecond) / 1_000_000, 0.0)
  end

  defp tokenize(text), do: String.split(text, ~r/\s+/, trim: true)

  # A payload is a JSON object carrying whatever happened. Where it names its
  # text, that is the text; where it does not, the encoded object stands in, so
  # a structured record still contributes its shape rather than being skipped.
  # Either way what leaves is a hash of it.
  defp extract_text(payload) when is_map(payload) do
    case payload["content"] || payload["text"] || payload["message"] || payload["output"] do
      value when is_binary(value) -> value
      nil -> Jason.encode!(payload)
      value -> Jason.encode!(value)
    end
  end

  defp extract_text(payload) when is_binary(payload), do: payload
  defp extract_text(_payload), do: ""

  # One model call ends when the model either asks for a tool or answers.
  defp terminating?("turn.assistant"), do: true
  defp terminating?("tool." <> _rest), do: true
  defp terminating?(_type), do: false

  defp model_authored?("turn.reasoning"), do: true
  defp model_authored?(type), do: terminating?(type)

  defp build_revision do
    version = to_string(Application.spec(:openagents, :vsn) || "unknown")
    version <> "+" <> to_string(BuildInfo.revision())
  end
end
