defmodule OpenAgents.Chat.AccountTurns do
  @moduledoc "Runs account-scoped `/chat` requests and journals their ordered events."

  import Ecto.Query
  alias OpenAgents.Accounts.User
  alias OpenAgents.Chat.{AccountEvent, AccountRun, OpenRouter}
  alias OpenAgents.Conversations
  alias OpenAgents.Repo

  @max_message_bytes 8_000

  def submit(user, content, options \\ [])

  def submit(%User{} = user, content, options) when is_binary(content) do
    content = String.trim(content)
    reasoning = OpenRouter.reasoning_effort(Keyword.get(options, :reasoning, "high"))
    subscriber = Keyword.get(options, :subscriber)
    streamer = Keyword.get(options, :streamer, &OpenRouter.stream/3)

    with :ok <- validate_content(content),
         {:ok, conversation} <- Conversations.ensure_conversation(user),
         {:ok, run} <- create_run(conversation.id, content, reasoning),
         {:ok, _pid} <- start_provider(run, user, subscriber, streamer) do
      {:ok, run_projection(run)}
    else
      {:provider_start_failed, run, reason} ->
        finish_run(run.id, {:error, :turn_start_failed})
        {:error, reason}

      error ->
        error
    end
  end

  def submit(%User{}, _content, _options), do: {:error, :invalid_message}

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

  defp validate_content(""), do: {:error, :empty_message}

  defp validate_content(content) when byte_size(content) > @max_message_bytes,
    do: {:error, :message_too_long}

  defp validate_content(_content), do: :ok

  defp create_run(conversation_id, content, reasoning) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        run =
          %AccountRun{conversation_id: conversation_id}
          |> AccountRun.changeset(%{
            status: "streaming",
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

  defp start_provider(run, user, subscriber, streamer) do
    request = %{
      "model" => OpenRouter.default_model(),
      "models" => ["openrouter/free"],
      "reasoning" => run.reasoning_effort,
      "messages" =>
        provider_history(run.conversation_id, run.id) ++
          [%{"role" => "user", "content" => run.user_content}]
    }

    case Task.Supervisor.start_child(OpenAgents.ProviderTaskSupervisor, fn ->
           result =
             try do
               streamer.(
                 request,
                 fn event ->
                   persist_provider_event(run.id, event)
                   notify(subscriber, {:openrouter_stream_event, run.id, event})
                 end,
                 tool_context: %{
                   surface: "text",
                   conversation_id: run.conversation_id,
                   owner_visitor_id: user.id,
                   owner_user_id: user.id
                 }
               )
             rescue
               _error -> {:error, :provider_unavailable}
             catch
               _kind, _reason -> {:error, :provider_unavailable}
             end

           finish_run(run.id, result)
           notify(subscriber, {:account_chat_completed, run.id, result})
         end) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:provider_start_failed, run, reason}
    end
  end

  defp persist_provider_event(run_id, {kind, payload}),
    do: append_event(run_id, Atom.to_string(kind), normalize_payload(payload))

  defp finish_run(run_id, {:ok, completion}) do
    completion = OpenAgents.Tools.Redaction.redact(completion)

    terminal_update(run_id, "response_completed", completion, %{
      status: "completed",
      assistant_content: completion["assistant_content"] || "",
      completion: completion
    })
  end

  defp finish_run(run_id, {:error, reason}) do
    error = public_error(reason)

    terminal_update(run_id, "response_failed", %{"reason" => error}, %{
      status: "failed",
      error: error
    })
  end

  defp terminal_update(run_id, kind, payload, attrs) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      run = Repo.one!(from r in AccountRun, where: r.id == ^run_id, lock: "FOR UPDATE")
      append_event_locked!(run, kind, payload, now)
      run |> AccountRun.changeset(Map.put(attrs, :completed_at, now)) |> Repo.update!()
    end)
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

  defp provider_history(conversation_id, excluded_run_id) do
    from(r in AccountRun,
      where:
        r.conversation_id == ^conversation_id and r.id != ^excluded_run_id and
          r.status == "completed",
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
    |> Enum.map(&event_projection/1)
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
        acc ++
          [
            %{
              call_id: payload["call_id"],
              name: payload["name"],
              arguments: format_json(payload["arguments"]),
              output: nil,
              error: nil,
              state: "input-available"
            }
          ]

      %{kind: "tool_call_completed", payload: payload}, acc ->
        update_tool(acc, payload["call_id"], %{
          output: format_json(payload["output"]),
          state: "output-available"
        })

      %{kind: "tool_call_failed", payload: payload}, acc ->
        update_tool(acc, payload["call_id"], %{error: payload["error"], state: "output-error"})

      _event, acc ->
        acc
    end)
  end

  defp update_tool(tools, call_id, attrs),
    do:
      Enum.map(tools, fn tool ->
        if tool.call_id == call_id, do: Map.merge(tool, attrs), else: tool
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
  defp public_error(:missing_api_key), do: "OpenRouter is not configured for this environment."
  defp public_error(:rate_limited), do: "OpenRouter is rate-limited. Try again later."
  defp public_error(:provider_unavailable), do: "OpenRouter could not complete that message."
  defp public_error(:turn_start_failed), do: "The chat turn could not start."
  defp public_error(_reason), do: "OpenRouter could not complete that message."
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp notify(pid, message) when is_pid(pid), do: send(pid, message)
  defp notify(_pid, _message), do: :ok

  defp duration(%{started_at: %DateTime{} = started, completed_at: %DateTime{} = completed}),
    do: max(DateTime.diff(completed, started), 1)

  defp duration(_run), do: nil

  defp event_projection(event),
    do: %{
      "id" => event.id,
      "run_id" => event.run_id,
      "sequence" => event.sequence,
      "type" => event.kind,
      "payload" => event.payload,
      "observed_at" => DateTime.to_iso8601(event.observed_at)
    }

  defp run_projection(run),
    do: %{
      "id" => run.id,
      "status" => run.status,
      "reasoning_effort" => run.reasoning_effort,
      "started_at" => DateTime.to_iso8601(run.started_at)
    }
end
