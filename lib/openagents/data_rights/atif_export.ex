defmodule OpenAgents.DataRights.AtifExport do
  @moduledoc """
  Builds one Agent Trajectory Interchange Format (ATIF v1.7) document for an
  account's whole conversation.

  The mapping is a bounded projection of PostgreSQL truth, in the same
  authorization shape as `OpenAgents.DataRights.export/3`: it accepts only the
  active user, the visitor root that user owns, and that root's conversation.

  Mapping summary (the full contract lives in issue #71):

    * Every durable message on either surface becomes one step, merged into a
      single chronological sequence with `step_id` counted from 1.
    * A typed turn's tool steps group onto that turn's assistant step;
      a Realtime response's voice tool steps group onto that response's
      assistant step, or onto a synthetic empty-message agent step when the
      response produced only a function call and no speech.
    * Every `tool_calls` entry carries the durable raw arguments (steps
      persisted before raw-argument retention, issue #72, fall back to an
      empty object) plus the canonical SHA-256 digest, durable status, and
      executor disclosure in `extra`; the observation result carries the
      bounded durable result or error JSON under the same call id.
    * Metrics come from turn receipts and voice response receipts;
      `final_metrics` sums turn receipts plus voice session usage, which are
      the two authoritative merged totals (`OpenAgents.Leaderboard` uses the same
      rule to avoid double counting).
  """

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Conversations.{Conversation, Message, ProviderStep, ToolStep, Turn, Visitor}
  alias OpenAgents.Repo
  alias OpenAgents.Tools.Registry
  alias OpenAgents.Voice.Session
  alias OpenAgents.Voice.ToolStep, as: VoiceToolStep

  @schema_version "ATIF-v1.7"
  @agent_name "simply-sarah"
  @maximum_export_messages 10_000
  @maximum_export_voice_sessions 2_000
  @maximum_content_bytes 8_192
  @truncation_marker " …[truncated by export bound]"

  @notes "Sarah records two surfaces — typed text and Realtime voice — into one " <>
           "conversation, so steps merge both surfaces chronologically by durable " <>
           "insertion time and each step names its surface in extra. Tool calls " <>
           "carry the durable raw arguments (empty for steps persisted before " <>
           "raw-argument retention) plus their canonical SHA-256 digest, durable " <>
           "status, and executor disclosure in extra, and the observation carries " <>
           "the bounded durable result or error JSON. A typed turn persists one " <>
           "assistant message even when the provider looped over several LLM calls, " <>
           "so a text agent step aggregates that turn's tool calls and merged usage " <>
           "and reports the provider call count as llm_call_count. A voice response " <>
           "that produced only a function call has no assistant message and appears " <>
           "as an agent step with an empty message. Steps whose extra carries " <>
           "interrupted: true were cut off mid-speech and are labeled evidence, not " <>
           "completed claims. final_metrics sums turn receipts plus voice session " <>
           "usage (the merged totals, so per-response receipts are not double " <>
           "counted); voice cost is a conservative estimate converted from " <>
           "microusd, and unpriced usage carries no cost."

  @spec build(User.t(), Visitor.t(), Conversation.t()) :: {:ok, map()}
  def build(
        %User{id: user_id},
        %Visitor{id: visitor_id, user_id: user_id},
        %Conversation{visitor_id: visitor_id} = conversation
      ) do
    messages = load_messages(conversation)
    bounded_messages = Enum.take(messages, @maximum_export_messages)
    turns = load_turns(conversation)
    sessions = load_sessions(conversation)
    bounded_sessions = Enum.take(sessions, @maximum_export_voice_sessions)

    provider_call_counts = provider_call_counts(turns)
    turn_by_assistant_message = Map.new(turns, &{&1.assistant_message_id, &1})
    session_by_id = Map.new(bounded_sessions, &{&1.id, &1})

    receipts = Enum.flat_map(bounded_sessions, & &1.response_receipts)

    receipt_by_assistant_message =
      receipts
      |> Enum.filter(& &1.assistant_message_id)
      |> Map.new(&{&1.assistant_message_id, &1})

    context = %{
      turns: turn_by_assistant_message,
      receipts: receipt_by_assistant_message,
      sessions: session_by_id,
      provider_call_counts: provider_call_counts
    }

    steps =
      bounded_messages
      |> Enum.map(&{&1.inserted_at, 0, {:message, &1}})
      |> Kernel.++(tool_only_response_events(receipts))
      |> Enum.sort_by(fn {at, tie, _event} -> {DateTime.to_unix(at, :microsecond), tie} end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{_at, _tie, event}, step_id} -> step(event, step_id, context) end)

    {:ok,
     %{
       "schema_version" => @schema_version,
       "session_id" => conversation.id,
       "trajectory_id" => conversation.id,
       "agent" => agent(),
       "notes" => @notes,
       "steps" => steps,
       "final_metrics" => final_metrics(turns, bounded_sessions, length(steps)),
       "extra" => %{
         "exporter" => "sarah.atif_export.v1",
         "scope" => "authenticated_github_user",
         "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
         "messages_truncated" => length(messages) > @maximum_export_messages,
         "voice_sessions_truncated" => length(sessions) > @maximum_export_voice_sessions
       }
     }}
  end

  defp load_messages(conversation) do
    Repo.all(
      from(message in Message,
        where: message.conversation_id == ^conversation.id,
        order_by: [asc: message.inserted_at, asc: message.id],
        limit: ^(@maximum_export_messages + 1)
      )
    )
  end

  defp load_turns(conversation) do
    tool_steps_query = from(step in ToolStep, order_by: [asc: step.sequence])

    Repo.all(
      from(turn in Turn,
        where: turn.conversation_id == ^conversation.id,
        preload: [:receipt, tool_steps: ^tool_steps_query]
      )
    )
  end

  defp load_sessions(conversation) do
    voice_steps_query =
      from(step in VoiceToolStep, order_by: [asc: step.generation, asc: step.sequence])

    receipts_query =
      from(receipt in OpenAgents.Voice.ResponseReceipt,
        order_by: [asc: receipt.generation, asc: receipt.started_event_sequence]
      )

    Repo.all(
      from(session in Session,
        where: session.conversation_id == ^conversation.id,
        order_by: [asc: session.started_at, asc: session.generation],
        limit: ^(@maximum_export_voice_sessions + 1),
        preload: [response_receipts: ^{receipts_query, tool_steps: voice_steps_query}]
      )
    )
  end

  defp provider_call_counts(turns) do
    receipt_ids = for turn <- turns, receipt = turn.receipt, receipt != nil, do: receipt.id

    if receipt_ids == [] do
      %{}
    else
      Repo.all(
        from(step in ProviderStep,
          where: step.turn_receipt_id in ^receipt_ids,
          group_by: step.turn_receipt_id,
          select: {step.turn_receipt_id, count(step.id)}
        )
      )
      |> Map.new()
    end
  end

  # A Realtime response that only requested a function call persists no
  # assistant message, so its tool evidence gets its own agent step.
  defp tool_only_response_events(receipts) do
    for receipt <- receipts,
        receipt.assistant_message_id == nil,
        receipt.tool_steps != [] do
      {receipt.inserted_at, 1, {:voice_tool_response, receipt}}
    end
  end

  defp step({:message, %Message{role: "assistant"} = message}, step_id, context) do
    base = base_step(step_id, message.inserted_at, "agent", message.content)

    cond do
      turn = context.turns[message.id] ->
        decorate_text_turn(base, message, turn, context.provider_call_counts)

      receipt = context.receipts[message.id] ->
        decorate_voice_response(base, message, receipt, context.sessions)

      true ->
        Map.put(base, "extra", message_extra(message))
    end
  end

  defp step({:message, %Message{} = message}, step_id, context) do
    source = if message.role == "system", do: "system", else: "user"

    step_id
    |> base_step(message.inserted_at, source, message.content)
    |> Map.put("extra", message_extra(message))
    |> then(fn step ->
      if source == "user" and message.modality == "voice" do
        put_in(step, ["extra", "voice_session_id"], session_ref(message, context.sessions))
      else
        step
      end
    end)
  end

  defp step({:voice_tool_response, receipt}, step_id, context) do
    session = context.sessions[receipt.voice_session_id]

    step_id
    |> base_step(receipt.inserted_at, "agent", "")
    |> put_tool_work(receipt.tool_steps)
    |> put_present("model_name", session && session.model_id)
    |> put_present("metrics", metrics(receipt.usage))
    |> Map.put("llm_call_count", 1)
    |> Map.put("extra", %{
      "surface" => "voice",
      "tool_only_response" => true,
      "interrupted" => receipt.status == "interrupted",
      "response_status" => receipt.status
    })
  end

  defp base_step(step_id, inserted_at, source, content) do
    %{
      "step_id" => step_id,
      "timestamp" => DateTime.to_iso8601(inserted_at),
      "source" => source,
      "message" => bound(content || "")
    }
  end

  defp decorate_text_turn(base, message, turn, provider_call_counts) do
    receipt = turn.receipt

    base
    |> put_tool_work(turn.tool_steps)
    |> put_present("model_name", receipt && receipt.model_id)
    |> put_present("metrics", receipt && metrics(receipt.usage))
    |> put_present("llm_call_count", receipt && provider_call_counts[receipt.id])
    |> Map.put(
      "extra",
      message
      |> message_extra()
      |> Map.put("turn_status", turn.status)
      |> put_present("turn_error", turn.error_message)
    )
  end

  defp decorate_voice_response(base, message, receipt, sessions) do
    session = sessions[receipt.voice_session_id]

    base
    |> put_tool_work(receipt.tool_steps)
    |> put_present("model_name", session && session.model_id)
    |> put_present("metrics", metrics(receipt.usage))
    |> Map.put("llm_call_count", 1)
    |> Map.put(
      "extra",
      message
      |> message_extra()
      |> Map.put("response_status", receipt.status)
    )
  end

  defp message_extra(message) do
    extra = %{"surface" => message.modality, "interrupted" => message.interrupted}

    if message.status == "complete" do
      extra
    else
      Map.put(extra, "message_status", message.status)
    end
  end

  defp session_ref(message, sessions) do
    case sessions[message.voice_session_id] do
      nil -> message.voice_session_id
      session -> session.id
    end
  end

  defp put_tool_work(step, []), do: step

  defp put_tool_work(step, tool_steps) do
    step
    |> Map.put("tool_calls", Enum.map(tool_steps, &tool_call/1))
    |> Map.put("observation", %{"results" => Enum.map(tool_steps, &observation_result/1)})
  end

  # Since issue #72 the durable step keeps the raw model arguments alongside
  # their canonical digest, so the export carries the real `arguments` object;
  # steps persisted before that change (or with undecodable payloads) fall
  # back to an honestly empty object, and the digest always travels in
  # `extra` where a consumer can verify a replay against it.
  defp tool_call(tool_step) do
    %{
      "tool_call_id" => tool_step.provider_call_id,
      "function_name" => tool_step.tool_name,
      "arguments" => decoded_arguments(tool_step),
      "extra" =>
        %{
          "argument_digest" => tool_step.argument_digest,
          "status" => tool_step.status,
          "module_id" => tool_step.module_id
        }
        |> put_present("executor_id", tool_step.executor_id)
        |> put_present("executor_disclosure", tool_step.executor_disclosure)
    }
  end

  defp decoded_arguments(%{raw_arguments: raw_arguments}) when is_binary(raw_arguments) do
    case Jason.decode(raw_arguments) do
      {:ok, arguments} when is_map(arguments) -> arguments
      _undecodable -> %{}
    end
  end

  defp decoded_arguments(_tool_step), do: %{}

  defp observation_result(tool_step) do
    content =
      cond do
        is_map(tool_step.result) -> bound_json(tool_step.result)
        is_map(tool_step.error) -> bound_json(tool_step.error)
        true -> ""
      end

    %{
      "source_call_id" => tool_step.provider_call_id,
      "content" => content,
      "extra" =>
        %{"status" => tool_step.status}
        |> put_present("outcome_digest", Map.get(tool_step, :outcome_digest))
    }
  end

  defp metrics(usage) when is_map(usage) do
    prompt = non_negative_integer(usage["input_tokens"])
    completion = non_negative_integer(usage["output_tokens"])
    cached = non_negative_integer(usage["input_cached_tokens"])

    if prompt + completion > 0 do
      %{"prompt_tokens" => prompt, "completion_tokens" => completion}
      |> then(fn metrics ->
        if cached > 0, do: Map.put(metrics, "cached_tokens", cached), else: metrics
      end)
      |> put_cost(usage)
    end
  end

  defp metrics(_usage), do: nil

  defp put_cost(metrics, usage) do
    if priced?(usage) do
      metrics
      |> Map.put("cost_usd", usage["estimated_cost_microusd"] / 1_000_000)
      |> Map.put("extra", %{"pricing_id" => usage["pricing_id"], "estimate" => true})
    else
      metrics
    end
  end

  defp priced?(usage) do
    is_binary(usage["pricing_id"]) and usage["pricing_id"] != "unpriced" and
      is_integer(usage["estimated_cost_microusd"])
  end

  # Turn receipts already merge every provider call of a typed turn, and a
  # voice session's usage already merges its responses, so these two sums are
  # the double-count-free totals (the same rule `OpenAgents.Leaderboard` documents).
  defp final_metrics(turns, sessions, total_steps) do
    usages =
      Enum.filter(
        Enum.map(turns, &(&1.receipt && &1.receipt.usage)) ++ Enum.map(sessions, & &1.usage),
        &is_map/1
      )

    total_cost_microusd =
      usages
      |> Enum.filter(&priced?/1)
      |> Enum.map(& &1["estimated_cost_microusd"])
      |> Enum.sum()

    %{
      "total_prompt_tokens" => sum_field(usages, "input_tokens"),
      "total_completion_tokens" => sum_field(usages, "output_tokens"),
      "total_steps" => total_steps
    }
    |> then(fn totals ->
      cached = sum_field(usages, "input_cached_tokens")
      if cached > 0, do: Map.put(totals, "total_cached_tokens", cached), else: totals
    end)
    |> then(fn totals ->
      if total_cost_microusd > 0 do
        Map.put(totals, "total_cost_usd", total_cost_microusd / 1_000_000)
      else
        totals
      end
    end)
  end

  defp sum_field(usages, field) do
    usages |> Enum.map(&non_negative_integer(&1[field])) |> Enum.sum()
  end

  defp agent do
    %{
      "name" => @agent_name,
      "version" => application_version(),
      "model_name" => Application.fetch_env!(:openagents, :openai_model),
      "tool_definitions" => tool_definitions()
    }
  end

  defp application_version do
    case Application.spec(:openagents, :vsn) do
      version when is_list(version) -> List.to_string(version)
      _unknown -> "unknown"
    end
  end

  defp tool_definitions do
    Registry.current!()
    |> Registry.provider_definitions()
    |> Enum.map(fn definition ->
      %{
        "type" => "function",
        "function" => %{
          "name" => definition.name,
          "description" => definition.description,
          "parameters" => definition.input_schema
        }
      }
    end)
  end

  # JSON observation content must STAY valid JSON under the byte bound —
  # truncating an encoded document mid-string hands consumers unparseable
  # content. Oversized maps get their longest string values trimmed (largest
  # first) until the encoding fits; only a pathological map that cannot fit
  # even trimmed falls back to a stub that is itself valid JSON.
  @doc false
  def bound_json(map) when is_map(map) do
    encoded = Jason.encode!(map)

    if byte_size(encoded) <= @maximum_content_bytes do
      encoded
    else
      excess = byte_size(encoded) - @maximum_content_bytes

      trimmed =
        map
        |> Enum.sort_by(
          fn {_key, value} -> if(is_binary(value), do: byte_size(value), else: 0) end,
          :desc
        )
        |> Enum.reduce({map, excess}, fn {key, value}, {acc, remaining} ->
          if remaining > 0 and is_binary(value) and byte_size(value) > 256 do
            keep = max(byte_size(value) - remaining - byte_size(@truncation_marker), 256)

            shortened =
              value
              |> binary_part(0, keep)
              |> valid_utf8_prefix()
              |> Kernel.<>(@truncation_marker)

            {Map.put(acc, key, shortened), remaining - (byte_size(value) - byte_size(shortened))}
          else
            {acc, remaining}
          end
        end)
        |> elem(0)

      reencoded = Jason.encode!(trimmed)

      if byte_size(reencoded) <= @maximum_content_bytes do
        reencoded
      else
        Jason.encode!(%{
          "truncated" => true,
          "note" => "result exceeded the export content bound",
          "schema" => map["schema"]
        })
      end
    end
  end

  defp bound(content) when byte_size(content) <= @maximum_content_bytes, do: content

  defp bound(content) do
    content
    |> binary_part(0, @maximum_content_bytes)
    |> valid_utf8_prefix()
    |> Kernel.<>(@truncation_marker)
  end

  defp valid_utf8_prefix(binary) do
    if String.valid?(binary) do
      binary
    else
      valid_utf8_prefix(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0
end
