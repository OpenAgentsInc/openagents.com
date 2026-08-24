defmodule OpenAgents.Chat.AccountTurns do
  @moduledoc "Runs account-scoped `/chat` requests and journals their ordered events."

  import Ecto.Query
  alias OpenAgents.Accounts.User
  alias OpenAgents.Analytics
  alias OpenAgents.Analytics.Chat, as: ChatAnalytics
  alias OpenAgents.Chat.{AccountEvent, AccountRun, Backends, OpenRouter}
  alias OpenAgents.Conversations
  alias OpenAgents.Repo

  @max_message_bytes 8_000
  @run_registry OpenAgents.Chat.RunRegistry
  @retryable_error_codes ~w(
    rate_limited
    service_unavailable
    stream_interrupted
    invalid_response
    provider_unavailable
    server_error
  )

  def submit(user, content, options \\ [])

  def submit(%User{} = user, content, options) when is_binary(content) do
    content = String.trim(content)
    reasoning = OpenRouter.reasoning_effort(Keyword.get(options, :reasoning, "high"))
    subscriber = Keyword.get(options, :subscriber)

    with {:ok, backend} <- Backends.fetch(Keyword.get(options, :backend)),
         streamer = Keyword.get(options, :streamer, Backends.streamer(backend)),
         :ok <- validate_content(content),
         {:ok, conversation} <- Conversations.ensure_conversation(user),
         owner <- Conversations.get_conversation_owner!(conversation),
         {:ok, run} <- create_run(conversation.id, content, reasoning, backend),
         {:ok, _pid} <- start_provider(run, user, owner, subscriber, streamer, backend) do
      {:ok, run_projection(run)}
    else
      {:provider_start_failed, run, reason} ->
        finish_run(run.id, {:error, :turn_start_failed}, Backends.default())
        capture_run_outcome(run, user, {:error, :turn_start_failed})
        {:error, reason}

      error ->
        error
    end
  end

  def submit(%User{}, _content, _options), do: {:error, :invalid_message}

  @doc """
  Stops the streaming run for this account.

  The provider task holds the open stream, so cancellation stops that task and
  then journals the cancellation in the same transaction that flips the run out
  of `streaming`. A run that already reached a terminal state stays there.
  """
  def cancel(%User{} = user) do
    with %{id: conversation_id} <- Conversations.get_conversation_for_user(user),
         %AccountRun{} = run <- streaming_run(conversation_id) do
      stop_provider_task(run.id)

      ChatAnalytics.turn_failed(Analytics.distinct_id(user), %{
        "reason" => "cancelled",
        "outcome" => "cancelled",
        "conversation_id" => conversation_id,
        "turn_id" => run.id
      })

      cancel_run(run.id)
    else
      _no_active_turn -> {:error, :no_active_turn}
    end
  end

  @doc "Whether an operator can retry the turn that recorded this error code."
  def retryable_error_code?(code) when is_binary(code), do: code in @retryable_error_codes
  def retryable_error_code?(_code), do: false

  def list_events(%User{} = user) do
    case Conversations.get_conversation_for_user(user) do
      nil -> []
      conversation -> events_for_conversation(conversation.id)
    end
  end

  def list_messages(%User{} = user) do
    case Conversations.get_conversation_for_user(user) do
      nil -> []
      conversation -> messages_for_conversation(conversation.id)
    end
  end

  @doc """
  Subscribes the caller to one account conversation's turns.

  `Conversations.subscribe/1` is the wrong topic for what `list_messages/1`
  renders: these turns are `account_chat_runs` rows and never become
  `Conversations.Message` rows, so a surface listening there hears nothing
  about them. The message is `{:account_turns_changed, conversation_id}` and
  carries nothing else, so a subscriber re-reads through `list_messages/1`,
  which resolves the caller's own conversation and can never hand it another
  account's turns.
  """
  def subscribe_turns(conversation_id) when is_binary(conversation_id),
    do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, turns_topic(conversation_id))

  @doc """
  Announces that a conversation's turns moved.

  Called after the owning transaction commits, never inside it: a subscriber
  re-reads the moment it hears, and an announcement from inside an open
  transaction hands it the conversation as it was.

  A turn announces when it starts, when it is cancelled, and when it reaches a
  terminal state -- the three points where `list_messages/1` returns something
  different. Streamed deltas do not announce: a run in `streaming` contributes
  only its user message to that projection, and the browser holding the stream
  already has the deltas.
  """
  def broadcast_turns(conversation_id) when is_binary(conversation_id) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      turns_topic(conversation_id),
      {:account_turns_changed, conversation_id}
    )
  end

  defp turns_topic(conversation_id), do: "account_turns:" <> conversation_id

  def active?(%User{} = user) do
    case Conversations.get_conversation_for_user(user) do
      nil ->
        false

      conversation ->
        Repo.exists?(
          from r in AccountRun,
            where: r.conversation_id == ^conversation.id and r.status == "streaming"
        )
    end
  end

  @doc "Projects the start of a tool call for the browser and account API."
  def tool_call_view(payload) when is_map(payload) do
    workspace = public_workspace(payload["workspace"])

    %{
      call_id: payload["call_id"],
      name: payload["name"] || "tool",
      arguments: format_json(payload["arguments"] || %{}),
      output: nil,
      error: nil,
      error_code: nil,
      state: "input-available",
      status: "running",
      workspace: workspace,
      workspace_label: workspace_label(workspace),
      duration_ms: nil,
      receipt_refs: []
    }
  end

  @doc "Applies one terminal tool event to the shared browser and account API projection."
  def apply_tool_event(tool, kind, payload) when is_map(tool) and is_map(payload) do
    outcome = tool_outcome(payload)
    error = tool_error(payload, outcome)
    status = outcome["status"] || fallback_tool_status(kind)
    workspace = public_workspace(outcome["workspace"] || payload["workspace"] || tool.workspace)
    result = outcome["result"] || legacy_tool_result(payload, outcome)

    Map.merge(tool, %{
      output: if(is_nil(result), do: nil, else: format_json(result)),
      error: error && error.message,
      error_code: error && error.code,
      state: tool_state(status, kind),
      status: status,
      workspace: workspace,
      workspace_label: workspace_label(workspace),
      duration_ms: tool_duration_ms(outcome),
      receipt_refs: outcome["target_receipt_refs"] || payload["target_receipt_refs"] || []
    })
  end

  defp validate_content(""), do: {:error, :empty_message}

  defp validate_content(content) when byte_size(content) > @max_message_bytes,
    do: {:error, :message_too_long}

  defp validate_content(_content), do: :ok

  defp create_run(conversation_id, content, reasoning, backend) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        run =
          %AccountRun{conversation_id: conversation_id}
          |> AccountRun.changeset(%{
            status: "streaming",
            backend: backend.id,
            reasoning_effort: reasoning,
            user_content: content,
            started_at: now
          })
          |> Repo.insert!()

        insert_event!(run.id, 1, "user_message", %{"content" => content}, now)
        run
      end)

    case result do
      {:ok, run} ->
        broadcast_turns(run.conversation_id)
        {:ok, run}

      {:error, %Ecto.Changeset{} = changeset} ->
        if Keyword.has_key?(changeset.errors, :conversation_id),
          do: {:error, :turn_in_progress},
          else: {:error, changeset}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    Ecto.ConstraintError ->
      {:error, :turn_in_progress}

    Ecto.InvalidChangesetError ->
      {:error, :turn_in_progress}
  end

  defp streaming_run(conversation_id) do
    Repo.one(
      from r in AccountRun,
        where: r.conversation_id == ^conversation_id and r.status == "streaming",
        order_by: [desc: r.inserted_at],
        limit: 1
    )
  end

  defp stop_provider_task(run_id) do
    case Registry.lookup(@run_registry, run_id) do
      [{pid, _value}] -> Process.exit(pid, :kill)
      [] -> :ok
    end
  end

  defp cancel_run(run_id) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        run = Repo.one!(from r in AccountRun, where: r.id == ^run_id, lock: "FOR UPDATE")

        if run.status == "streaming" do
          append_event_locked!(run, "response_cancelled", %{}, now)

          run
          |> AccountRun.changeset(%{
            status: "cancelled",
            assistant_content: streamed_text(run.id),
            completed_at: now,
            latency_ms: DateTime.diff(now, run.started_at, :millisecond)
          })
          |> Repo.update!()
        else
          Repo.rollback(:no_active_turn)
        end
      end)

    case result do
      {:ok, run} ->
        broadcast_turns(run.conversation_id)
        {:ok, run_projection(run)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp streamed_text(run_id) do
    from(e in AccountEvent,
      where: e.run_id == ^run_id and e.kind == "text_delta",
      order_by: [asc: e.sequence],
      select: e.payload
    )
    |> Repo.all()
    |> Enum.map_join("", fn payload -> payload["value"] || "" end)
  end

  # The tool context names the conversation's owning visitor, never the account.
  # `owner_visitor_id` is read back as a `visitors` row, so an account id here
  # resolves to nothing and every owner-requiring tool refuses the signed-in
  # caller as if they were signed out.
  defp start_provider(run, user, owner, subscriber, streamer, backend) do
    request = %{
      "model" => Backends.model(backend),
      "reasoning" => run.reasoning_effort,
      "messages" =>
        provider_history(run.conversation_id, run.id, backend) ++
          [%{"role" => "user", "content" => run.user_content}]
    }

    case Task.Supervisor.start_child(OpenAgents.ProviderTaskSupervisor, fn ->
           register_provider_task(run.id)

           result =
             try do
               streamer.(
                 request,
                 fn event ->
                   persist_provider_event(run.id, event)
                   capture_stream_event(run, user, event)
                   notify(subscriber, {:openrouter_stream_event, run.id, event})
                 end,
                 tool_context: %{
                   surface: "text",
                   conversation_id: run.conversation_id,
                   owner_visitor_id: owner.id,
                   owner_user_id: owner.user_id
                 }
               )
             rescue
               _error -> {:error, :provider_unavailable}
             catch
               _kind, _reason -> {:error, :provider_unavailable}
             end

           finish_run(run.id, result, backend)
           capture_run_outcome(run, user, result)
           notify(subscriber, {:account_chat_completed, run.id, result})
         end) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:provider_start_failed, run, reason}
    end
  end

  # Cancellation needs the process that holds the open stream, and the run id is
  # the only handle the browser has.
  defp register_provider_task(run_id) do
    case Registry.register(@run_registry, run_id, nil) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp persist_provider_event(run_id, {kind, payload}),
    do: append_event(run_id, Atom.to_string(kind), normalize_payload(payload))

  # One process owns one run's stream, so the chunk throttle lives in that
  # process rather than in a shared counter. Tool starts are already one event
  # per call and need no throttle.
  defp capture_stream_event(run, user, {:text_delta, _delta}) do
    captured_at =
      ChatAnalytics.stream_chunk(
        Analytics.distinct_id(user),
        Process.get(:chat_stream_chunk_captured_at),
        %{"conversation_id" => run.conversation_id, "turn_id" => run.id, "modality" => "text"}
      )

    Process.put(:chat_stream_chunk_captured_at, captured_at)
    :ok
  end

  defp capture_stream_event(run, user, {:tool_call_started, payload}) when is_map(payload) do
    ChatAnalytics.tool_called(Analytics.distinct_id(user), %{
      "tool_name" => payload["name"] || "tool",
      "turn_id" => run.id,
      "conversation_id" => run.conversation_id,
      "modality" => "text"
    })
  end

  defp capture_stream_event(_run, _user, _event), do: :ok

  # The completion carries the provider's own totals for the whole run,
  # including any Chat Completions fallback, so this is the one place a run
  # reports tokens.
  defp capture_run_outcome(run, user, {:ok, completion}) when is_map(completion) do
    distinct_id = Analytics.distinct_id(user)

    identity = %{
      "conversation_id" => run.conversation_id,
      "turn_id" => run.id,
      "modality" => "text"
    }

    ChatAnalytics.message_received(
      distinct_id,
      Map.put(
        identity,
        "length_bucket",
        ChatAnalytics.length_bucket(completion["assistant_content"] || "")
      )
    )

    ChatAnalytics.tokens_used(
      distinct_id,
      completion["usage"],
      Map.merge(identity, %{
        "model" => completion["model"],
        "provider" => completion["provider"],
        "outcome" => "completed"
      })
    )
  end

  defp capture_run_outcome(run, user, {:error, reason}) do
    ChatAnalytics.turn_failed(Analytics.distinct_id(user), %{
      "reason" => error_code(reason),
      "outcome" => "failed",
      "conversation_id" => run.conversation_id,
      "turn_id" => run.id
    })
  end

  defp capture_run_outcome(_run, _user, _result), do: :ok

  defp finish_run(run_id, {:ok, completion}, _backend) do
    # Token counts are read before redaction, which blanks every field whose
    # name contains `token`, and are stored beside the redacted completion.
    usage = usage_counts(completion)
    completion = OpenAgents.Tools.Redaction.redact(completion)

    terminal_update(run_id, "response_completed", completion, %{
      status: "completed",
      assistant_content: completion["assistant_content"] || "",
      completion: completion,
      usage: usage
    })
  end

  defp finish_run(run_id, {:error, reason}, backend) do
    error = public_error(reason, backend)
    code = error_code(reason)

    terminal_update(run_id, "response_failed", %{"reason" => error, "code" => code}, %{
      status: "failed",
      error: error,
      error_code: code
    })
  end

  defp terminal_update(run_id, kind, payload, attrs) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        run = Repo.one!(from r in AccountRun, where: r.id == ^run_id, lock: "FOR UPDATE")

        if run.status == "streaming" do
          append_event_locked!(run, kind, payload, now)

          attrs =
            attrs
            |> Map.put(:completed_at, now)
            |> Map.put(:latency_ms, DateTime.diff(now, run.started_at, :millisecond))

          run |> AccountRun.changeset(attrs) |> Repo.update!()
        else
          run
        end
      end)

    with {:ok, run} <- result, do: broadcast_turns(run.conversation_id)

    result
  end

  defp append_event(run_id, kind, payload) do
    Repo.transaction(fn ->
      run = Repo.one!(from r in AccountRun, where: r.id == ^run_id, lock: "FOR UPDATE")
      append_event_locked!(run, kind, payload, DateTime.utc_now())
    end)
  end

  defp append_event_locked!(run, kind, payload, observed_at) do
    sequence =
      Repo.one(from e in AccountEvent, where: e.run_id == ^run.id, select: max(e.sequence)) || 0

    insert_event!(run.id, sequence + 1, kind, payload, observed_at)
  end

  defp insert_event!(run_id, sequence, kind, payload, observed_at) do
    %AccountEvent{run_id: run_id}
    |> AccountEvent.changeset(%{
      sequence: sequence,
      kind: kind,
      payload: payload,
      observed_at: observed_at
    })
    |> Repo.insert!()
  end

  # History replays into the provider that wrote it. An OpenRouter Responses
  # output list is not a Gemini turn and vice versa, so a conversation that
  # switches backends replays only the turns the chosen backend produced rather
  # than handing one provider another's transcript shape. A row written before
  # backends were named is an Ox Alpha turn, which is what its `NULL` means.
  defp provider_history(conversation_id, excluded_run_id, backend) do
    default_id = Backends.default_id()

    from(r in AccountRun,
      where:
        r.conversation_id == ^conversation_id and r.id != ^excluded_run_id and
          r.status == "completed" and
          coalesce(r.backend, ^default_id) == ^backend.id,
      order_by: [asc: r.inserted_at, asc: r.id]
    )
    |> Repo.all()
    |> Enum.flat_map(fn run ->
      [%{"role" => "user", "content" => run.user_content}, provider_assistant(run)]
    end)
  end

  defp provider_assistant(run) do
    completion = run.completion || %{}

    case completion["output"] do
      output when is_list(output) ->
        %{"role" => "assistant", "provider_output" => output}

      _missing ->
        %{"role" => "assistant", "content" => run.assistant_content || ""}
        |> maybe_put("id", completion["assistant_message_id"])
        |> maybe_put("status", if(completion["assistant_message_id"], do: "completed"))
        |> maybe_put("reasoning_items", completion["reasoning_items"])
    end
  end

  defp events_for_conversation(conversation_id) do
    from(e in AccountEvent,
      join: r in assoc(e, :run),
      where: r.conversation_id == ^conversation_id,
      order_by: [asc: r.inserted_at, asc: r.id, asc: e.sequence]
    )
    |> Repo.all()
    |> event_projections()
  end

  defp messages_for_conversation(conversation_id) do
    event_query = from e in AccountEvent, order_by: [asc: e.sequence]

    from(r in AccountRun,
      where: r.conversation_id == ^conversation_id,
      order_by: [asc: r.inserted_at, asc: r.id],
      preload: [events: ^event_query]
    )
    |> Repo.all()
    |> Enum.flat_map(&run_messages/1)
  end

  defp run_messages(run) do
    user = %{
      id: run.id,
      role: :user,
      content: run.user_content,
      completion: nil,
      error: nil,
      history?: true,
      tool_calls: [],
      blocks: []
    }

    if run.status == "streaming", do: [user], else: [user, assistant_message(run)]
  end

  # Provider-reported counts only, stored as the provider sent them. OpenRouter
  # names them differently across its two APIs, and a field the provider left
  # out stays `nil` instead of a guess. What a stored zero means is decided when
  # the turn is read, not here, so a row keeps its evidence intact.
  defp usage_counts(%{"usage" => usage}) when is_map(usage) do
    counts = %{
      "input" => token_count(usage["input_tokens"] || usage["prompt_tokens"]),
      "output" => token_count(usage["output_tokens"] || usage["completion_tokens"]),
      "total" => token_count(usage["total_tokens"]),
      "reasoning" =>
        token_count(
          detail(usage, "output_tokens_details", "reasoning_tokens") ||
            detail(usage, "completion_tokens_details", "reasoning_tokens")
        ),
      "cached" =>
        token_count(
          detail(usage, "input_tokens_details", "cached_tokens") ||
            detail(usage, "prompt_tokens_details", "cached_tokens")
        )
    }

    if Enum.all?(Map.values(counts), &is_nil/1), do: nil, else: counts
  end

  defp usage_counts(_completion), do: nil

  defp usage_view(counts, completion) when is_map(counts),
    do: %{
      input: counts["input"],
      output: counts["output"],
      total: counts["total"],
      reasoning: reasoning_view(counts["reasoning"], completion),
      cached: counts["cached"]
    }

  defp usage_view(_counts, _completion), do: nil

  # Ox Alpha reports a reasoning count of zero for turns it plainly reasoned
  # through, so that zero measures nothing the turn did and the turn reports no
  # reasoning count rather than a count of none. The call is made here, against
  # the same stored reasoning the transcript renders, so a row written before
  # this rule reads the same way as one written after it and no stored count is
  # ever rewritten.
  defp reasoning_view(0, completion), do: if(reasoned?(completion), do: nil, else: 0)
  defp reasoning_view(count, _completion), do: count

  defp reasoned?(%{"reasoning_summary" => summary}) when is_binary(summary) and summary != "",
    do: true

  defp reasoned?(%{"reasoning_items" => [_item | _rest]}), do: true

  defp reasoned?(%{"output" => output}) when is_list(output),
    do: Enum.any?(output, &match?(%{"type" => "reasoning"}, &1))

  defp reasoned?(_completion), do: false

  defp detail(usage, key, field) do
    case usage[key] do
      details when is_map(details) -> details[field]
      _missing -> nil
    end
  end

  defp token_count(value) when is_integer(value) and value >= 0, do: value
  defp token_count(_value), do: nil

  defp assistant_message(run) do
    completion = run.completion
    reasoning = completion && completion["reasoning_summary"]
    tools = tool_views(run.events)

    %{
      id: run.id,
      role: :assistant,
      content: run.assistant_content || "",
      completion: completion,
      error: run.error,
      error_code: run.error_code,
      retryable?: retryable_error_code?(run.error_code),
      cancelled?: run.status == "cancelled",
      usage: usage_view(run.usage, completion),
      provider_lane: completion && completion["provider"],
      request_id: completion && completion["request_id"],
      latency_ms: run.latency_ms,
      history?: run.status == "completed",
      provider_message_id: completion && completion["assistant_message_id"],
      provider_status: if(completion && completion["assistant_message_id"], do: "completed"),
      provider_reasoning_items: completion && completion["reasoning_items"],
      reasoning: reasoning,
      reasoning_duration: duration(run),
      tool_calls: tools,
      blocks: blocks(run.events, run.assistant_content || "", reasoning, tools)
    }
  end

  defp blocks(events, content, reasoning, tools) do
    events
    |> Enum.reduce([], fn
      %{kind: "reasoning_delta", payload: %{"value" => delta}}, acc ->
        append_delta(acc, :reasoning, delta)

      %{kind: "text_delta", payload: %{"value" => delta}}, acc ->
        append_delta(acc, :content, delta)

      %{kind: "tool_call_started", payload: payload}, acc ->
        acc ++ [%{type: :tool, tool_call: Enum.find(tools, &(&1.call_id == payload["call_id"]))}]

      _event, acc ->
        acc
    end)
    |> ensure_reasoning(reasoning)
    |> ensure_content(content)
    |> Enum.map(fn
      %{type: :reasoning} = block -> Map.put(block, :duration, 1)
      block -> block
    end)
  end

  defp append_delta(blocks, type, delta) do
    case List.last(blocks) do
      %{type: ^type} = block -> List.replace_at(blocks, -1, %{block | text: block.text <> delta})
      _ -> blocks ++ [%{type: type, text: delta}]
    end
  end

  defp ensure_reasoning(blocks, reasoning) when is_binary(reasoning) and reasoning != "",
    do:
      if(Enum.any?(blocks, &(&1.type == :reasoning)),
        do: blocks,
        else: [%{type: :reasoning, text: reasoning} | blocks]
      )

  defp ensure_reasoning(blocks, _reasoning), do: blocks

  defp ensure_content(blocks, content) when is_binary(content) and content != "",
    do:
      if(Enum.any?(blocks, &(&1.type == :content)),
        do: blocks,
        else: blocks ++ [%{type: :content, text: content}]
      )

  defp ensure_content(blocks, _content), do: blocks

  defp tool_views(events) do
    Enum.reduce(events, [], fn
      %{kind: "tool_call_started", payload: payload}, acc ->
        acc ++ [tool_call_view(payload)]

      %{kind: "tool_call_completed", payload: payload}, acc ->
        update_tool(
          acc,
          payload["call_id"],
          &apply_tool_event(&1, "tool_call_completed", payload)
        )

      %{kind: "tool_call_failed", payload: payload}, acc ->
        update_tool(acc, payload["call_id"], &apply_tool_event(&1, "tool_call_failed", payload))

      _event, acc ->
        acc
    end)
  end

  defp update_tool(tools, call_id, update),
    do:
      Enum.map(tools, fn tool ->
        if tool.call_id == call_id, do: update.(tool), else: tool
      end)

  defp format_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> value
    end
  end

  defp format_json(value), do: Jason.encode!(value, pretty: true)

  defp normalize_payload(payload) when is_map(payload),
    do: OpenAgents.Tools.Redaction.redact(payload)

  defp normalize_payload(payload), do: %{"value" => OpenAgents.Tools.Redaction.redact(payload)}
  # A failure names the backend that failed. A turn answered by Gemini that
  # reports OpenRouter as unavailable sends the reader to the wrong provider,
  # and with more than one backend that is now a reachable mistake rather than
  # a hypothetical one.
  defp public_error(reason, %{label: label}), do: public_error(reason, label)

  defp public_error(:missing_api_key, label),
    do: "#{label} is not configured for this environment."

  defp public_error(:rate_limited, label), do: "#{label} is rate-limited. Try again."

  defp public_error(:service_unavailable, label),
    do: "#{label} is unavailable right now. Try again."

  defp public_error(:stream_interrupted, _label),
    do: "The response stream stopped before it finished. Try again."

  defp public_error(:invalid_response, label),
    do: "#{label} returned a response this console could not read. Try again."

  defp public_error(:provider_unavailable, label),
    do: "#{label} could not complete that message."

  defp public_error(:turn_start_failed, _label), do: "The chat turn could not start."
  defp public_error(_reason, label), do: "#{label} could not complete that message."

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({:provider_error, code, _detail}) when is_binary(code), do: code
  defp error_code(_reason), do: "provider_error"
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp notify(pid, message) when is_pid(pid), do: send(pid, message)
  defp notify(_pid, _message), do: :ok

  defp duration(%{started_at: %DateTime{} = started, completed_at: %DateTime{} = completed}),
    do: max(DateTime.diff(completed, started), 1)

  defp duration(_run), do: nil

  defp event_projections(events) do
    {projections, _tools} =
      Enum.reduce(events, {[], %{}}, fn event, {projections, tools} ->
        {tool, tools} = project_event_tool(event, tools)
        projection = event_projection(event) |> maybe_put("tool_call", tool && public_tool(tool))
        {projections ++ [projection], tools}
      end)

    projections
  end

  defp project_event_tool(%{kind: "tool_call_started", payload: payload, run_id: run_id}, tools) do
    tool = tool_call_view(payload)
    {tool, Map.put(tools, {run_id, tool.call_id}, tool)}
  end

  defp project_event_tool(%{kind: kind, payload: payload, run_id: run_id}, tools)
       when kind in ["tool_call_completed", "tool_call_failed"] do
    key = {run_id, payload["call_id"]}
    tool = tools |> Map.get(key, tool_call_view(payload)) |> apply_tool_event(kind, payload)
    {tool, Map.put(tools, key, tool)}
  end

  defp project_event_tool(_event, tools), do: {nil, tools}

  defp public_tool(tool) do
    %{
      "call_id" => tool.call_id,
      "name" => tool.name,
      "arguments" => tool.arguments,
      "output" => tool.output,
      "error" =>
        if(tool.error,
          do: %{"code" => tool.error_code, "message" => tool.error},
          else: nil
        ),
      "state" => tool.state,
      "status" => tool.status,
      "workspace" => tool.workspace,
      "duration_ms" => tool.duration_ms,
      "receipt_refs" => tool.receipt_refs
    }
  end

  defp tool_outcome(payload) do
    value = payload["outcome"] || payload["output"]

    case value do
      %{} = outcome ->
        outcome

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, %{} = outcome} -> outcome
          _other -> %{}
        end

      _other ->
        %{}
    end
  end

  defp legacy_tool_result(payload, outcome) do
    cond do
      outcome["schema"] == "sarah.tool_outcome.v1" -> nil
      map_size(outcome) > 0 -> outcome
      Map.has_key?(payload, "output") -> payload["output"]
      true -> nil
    end
  end

  defp tool_error(payload, outcome) do
    error = outcome["error"] || payload["error"]

    case error do
      %{} -> %{code: error["code"], message: error["message"] || "The tool failed."}
      value when is_binary(value) -> %{code: payload["error_code"], message: value}
      _other -> nil
    end
  end

  defp fallback_tool_status("tool_call_completed"), do: "succeeded"
  defp fallback_tool_status(_kind), do: "failed"

  defp tool_state("succeeded", _kind), do: "output-available"
  defp tool_state("denied", _kind), do: "output-denied"
  defp tool_state(_status, "tool_call_completed"), do: "output-available"
  defp tool_state(_status, _kind), do: "output-error"

  defp tool_duration_ms(outcome) do
    with started when is_binary(started) <- outcome["started_at"],
         completed when is_binary(completed) <- outcome["completed_at"],
         {:ok, started_at, _offset} <- DateTime.from_iso8601(started),
         {:ok, completed_at, _offset} <- DateTime.from_iso8601(completed) do
      max(DateTime.diff(completed_at, started_at, :millisecond), 0)
    else
      _other -> outcome["duration_ms"]
    end
  end

  defp workspace_label(nil), do: nil

  defp workspace_label(workspace) when is_map(workspace) do
    workspace["path"] || workspace["repository"] || workspace["type"] || format_json(workspace)
  end

  defp workspace_label(workspace), do: to_string(workspace)

  defp event_projection(event),
    do: %{
      "id" => event.id,
      "run_id" => event.run_id,
      "sequence" => event.sequence,
      "type" => event.kind,
      "payload" => public_event_payload(event.payload),
      "observed_at" => DateTime.to_iso8601(event.observed_at)
    }

  # Tool outcomes can contain an absolute path to a host worktree. Keep the
  # useful workspace identity in account-facing projections without exposing
  # the host directory layout.
  defp public_event_payload(payload) when is_map(payload) do
    Enum.into(payload, %{}, fn
      {"workspace", workspace} -> {"workspace", public_workspace(workspace)}
      {key, value} -> {key, public_payload_value(value)}
    end)
  end

  defp public_event_payload(payload), do: payload

  defp public_payload_value(value) when is_map(value), do: public_event_payload(value)

  defp public_payload_value(value) when is_list(value),
    do: Enum.map(value, &public_payload_value/1)

  defp public_payload_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = decoded} -> decoded |> public_event_payload() |> Jason.encode!()
      _other -> value
    end
  end

  defp public_payload_value(value), do: value

  defp public_workspace(nil), do: nil

  defp public_workspace(workspace) when is_map(workspace) do
    workspace
    |> OpenAgents.Tools.Redaction.redact()
    |> Enum.reduce(%{}, fn
      {key, value}, acc when key in ["path", "root"] and is_binary(value) ->
        Map.put(acc, key, public_workspace_path(value))

      {key, value}, acc ->
        Map.put(acc, key, public_payload_value(value))
    end)
  end

  defp public_workspace(workspace), do: workspace

  defp public_workspace_path(path) do
    if Path.type(path) == :absolute, do: Path.basename(path), else: path
  end

  # The accepted turn names the backend it went to. A caller that sent no
  # `model` still learns which one answered, so a default it did not choose is
  # never something it has to infer.
  defp run_projection(run),
    do: %{
      "id" => run.id,
      "status" => run.status,
      "model" => run.backend,
      "provider_model" => Backends.model(Backends.fetch!(run.backend)),
      "reasoning_effort" => run.reasoning_effort,
      "latency_ms" => run.latency_ms,
      "started_at" => DateTime.to_iso8601(run.started_at)
    }
end
