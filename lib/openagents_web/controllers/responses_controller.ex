defmodule OpenAgentsWeb.ResponsesController do
  @moduledoc """
  The OpenResponses surface, answered by real inference.

  `POST /api/v1/responses` takes an OpenResponses request — `input` as a
  string or a list of items, optional `instructions`, optional
  `max_output_tokens`, optional catalog `model` — and answers from the
  model's provider. The default model is `gemini-3.7-flash`.

  Both of the specification's answer shapes are served. Without `stream`,
  the non-streaming response object. With `"stream": true`, server-sent
  events carrying the semantic sequence — `response.created`,
  `response.output_item.added`, `response.content_part.added`, a
  `response.output_text.delta` per provider delta (and
  `response.reasoning_summary_text.delta` where the model thinks out loud),
  the matching `done` events, and `response.completed` — each numbered by
  `sequence_number` and flushed as it happens, so the client reads tokens
  while the provider is still writing them. A provider failure after the
  stream has opened arrives as `response.failed`, which is the
  specification's shape for exactly that.

  The system prompt is deliberately minimal: the caller's `instructions`
  when given, one sentence otherwise. This surface adds no context of its
  own — what the coder wants the model to know arrives in the request.

  This codebase has long spoken OpenResponses as a client
  (`OpenAgents.Providers.OpenAI` at `/v1/responses` upstream); this is where
  it answers as one.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Inference.Models
  alias OpenAgents.Providers.{Request, ToolDefinition, ToolOutput}
  alias OpenAgentsWeb.ApiError

  @default_model "gemini-3.7-flash"
  @default_instructions "You are OpenAgents Coder. Answer directly and concisely."

  def create(conn, params) do
    with {:ok, input} <- input_of(params),
         {:ok, model} <- model_of(params),
         :ok <- serving(model) do
      request = build_request(model, input, params)

      if params["stream"] == true do
        stream(conn, model, request)
      else
        collect(conn, model, request)
      end
    else
      {:error, :input_missing} ->
        ApiError.validation_failed(conn, %{"input" => ["is required"]})

      {:error, {:model_not_served, requested}} ->
        ApiError.validation_failed(conn, %{"model" => ["`#{requested}` is not in the catalog"]})

      {:error, :model_unavailable} ->
        ApiError.refuse(conn, "model_unavailable")
    end
  end

  # ── request shape ────────────────────────────────────────────────────────

  defp input_of(params) do
    case params["input"] do
      input when is_binary(input) and input != "" ->
        {:ok, {[%{role: "user", content: input}], []}}

      [_ | _] = items ->
        {:ok, {Enum.flat_map(items, &item_message/1), Enum.flat_map(items, &item_output/1)}}

      _missing ->
        {:error, :input_missing}
    end
  end

  # One OpenResponses input item as a provider message. Text rides in
  # `content` as a string or as `input_text`/`output_text` blocks; a replayed
  # `function_call` item becomes the assistant turn that asked for it, its
  # arguments the raw string the model produced, never interpreted. Anything
  # else contributes nothing rather than failing the request.
  defp item_message(%{"type" => "function_call"} = item) do
    call_id = string_or(item["call_id"], "")
    name = string_or(item["name"], "")

    if call_id == "" or name == "" do
      []
    else
      [
        %{
          role: "assistant",
          content: item_text(item["content"]),
          tool_calls: [
            %{call_id: call_id, name: name, arguments: string_or(item["arguments"], "{}")}
          ]
        }
      ]
    end
  end

  defp item_message(%{"type" => "function_call_output"}), do: []

  defp item_message(%{"role" => role} = item) when role in ["user", "assistant", "system"] do
    case item_text(item["content"]) do
      "" -> []
      text -> [%{role: role, content: text}]
    end
  end

  defp item_message(_item), do: []

  # A `function_call_output` item answers a replayed call; the provider takes
  # it as a tool output keyed by the call id.
  defp item_output(%{"type" => "function_call_output"} = item) do
    call_id = string_or(item["call_id"], "")

    if call_id == "" do
      []
    else
      [%ToolOutput{call_id: call_id, output: %{"content" => item_text(item["output"])}}]
    end
  end

  defp item_output(_item), do: []

  defp string_or(value, _fallback) when is_binary(value) and value != "", do: value
  defp string_or(_value, fallback), do: fallback

  # OpenResponses function tools are flat (`{type, name, description,
  # parameters}`); the chat-completions nesting is accepted too, because the
  # first client of this surface converted from that shape.
  defp declared_tools(tools) when is_list(tools) do
    Enum.flat_map(tools, fn
      %{"name" => name} = tool when is_binary(name) and name != "" ->
        [
          %ToolDefinition{
            name: name,
            description: string_or(tool["description"], ""),
            input_schema: Map.get(tool, "parameters") || %{},
            strict: false
          }
        ]

      %{"function" => %{"name" => name} = function} when is_binary(name) ->
        [
          %ToolDefinition{
            name: name,
            description: string_or(function["description"], ""),
            input_schema: Map.get(function, "parameters") || %{},
            strict: false
          }
        ]

      _other ->
        []
    end)
  end

  defp declared_tools(_tools), do: []

  defp item_text(content) when is_binary(content), do: content

  defp item_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      _other -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp item_text(_other), do: ""

  defp model_of(params) do
    case params["model"] do
      absent when absent in [nil, ""] ->
        case Models.fetch(@default_model) do
          {:ok, model} -> {:ok, model}
          :error -> {:error, {:model_not_served, @default_model}}
        end

      named when is_binary(named) ->
        case Models.fetch(named) do
          {:ok, model} -> {:ok, model}
          :error -> {:error, {:model_not_served, named}}
        end

      _not_a_string ->
        {:error, {:model_not_served, "a non-string model"}}
    end
  end

  defp serving(model) do
    if Models.available?(model), do: :ok, else: {:error, :model_unavailable}
  end

  defp build_request(model, {messages, tool_outputs}, params) do
    {system, turns} = Enum.split_with(messages, &(&1.role == "system"))

    instructions =
      case params["instructions"] do
        text when is_binary(text) and text != "" -> text
        _absent -> joined_or_default(system)
      end

    max_output =
      case params["max_output_tokens"] do
        tokens when is_integer(tokens) and tokens > 0 -> min(tokens, model.max_output)
        _absent -> model.max_output
      end

    %Request{
      model_id: model.provider_model,
      instructions: instructions,
      input: turns,
      tool_definitions: declared_tools(params["tools"]),
      tool_outputs: tool_outputs,
      max_output: max_output
    }
  end

  defp joined_or_default([]), do: @default_instructions
  defp joined_or_default(system), do: Enum.map_join(system, "\n\n", & &1.content)

  # ── streaming ────────────────────────────────────────────────────────────

  # Each provider delta becomes one OpenResponses event, flushed as it
  # arrives. The adapter runs in this process and pushes through the
  # callback synchronously, so the chunk is on the wire before the provider
  # writes the next one — this surface streams for real, where the
  # chat-completions proxy deliberately buffers.
  #
  # The callback cannot rebind outer variables, so the small amount of turn
  # state — the sequence number, the accumulated text — lives in the process
  # dictionary of this request's own process, scoped to this function.
  defp stream(conn, model, request) do
    response_id = "resp_" <> identifier()
    message_id = "msg_" <> identifier()
    base = %{"item_id" => message_id, "output_index" => 0, "content_index" => 0}
    started = shell(response_id, model_name(model), "in_progress", [])

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-store")
      |> send_chunked(200)

    Process.put(:responses_seq, 0)
    Process.put(:responses_text, [])
    Process.put(:responses_usage, %{})
    Process.put(:responses_calls, [])
    # The conn rides the process dictionary too: `chunk/2` returns the conn
    # that carries what has been sent — on the test adapter, literally the
    # accumulated body — and a closure cannot rebind the outer variable.
    Process.put(:responses_conn, conn)

    emit = fn type, payload ->
      sequence = Process.get(:responses_seq)
      Process.put(:responses_seq, sequence + 1)

      data =
        payload
        |> Map.put("type", type)
        |> Map.put("sequence_number", sequence)
        |> Jason.encode!()

      case chunk(Process.get(:responses_conn), "event: #{type}\ndata: #{data}\n\n") do
        {:ok, sent} -> Process.put(:responses_conn, sent)
        {:error, _closed} -> :ok
      end

      :ok
    end

    emit.("response.created", %{"response" => started})

    emit.("response.output_item.added", %{
      "output_index" => 0,
      "item" => message(message_id, "in_progress", [])
    })

    emit.("response.content_part.added", Map.put(base, "part", text_part("")))

    result =
      model.adapter.stream(request, fn
        {:text_delta, text} when is_binary(text) and text != "" ->
          Process.put(:responses_text, [Process.get(:responses_text), text])
          emit.("response.output_text.delta", Map.put(base, "delta", text))

        {:reasoning_delta, text} when is_binary(text) and text != "" ->
          emit.("response.reasoning_summary_text.delta", Map.put(base, "delta", text))

        {:usage, usage} when is_map(usage) ->
          Process.put(:responses_usage, usage)
          :ok

        # A tool call the model asked for: one function_call item, whole,
        # because the provider hands the call assembled rather than in
        # fragments. The item's own done-events follow immediately.
        {:tool_call, call} ->
          calls = Process.get(:responses_calls)
          Process.put(:responses_calls, calls ++ [call])
          index = length(calls) + 1
          item = function_call_item(call, "completed")

          emit.("response.output_item.added", %{
            "output_index" => index,
            "item" => %{item | "status" => "in_progress"}
          })

          emit.("response.function_call_arguments.done", %{
            "item_id" => item["id"],
            "output_index" => index,
            "arguments" => item["arguments"]
          })

          emit.("response.output_item.done", %{"output_index" => index, "item" => item})

        _other ->
          :ok
      end)

    text = IO.iodata_to_binary(Process.get(:responses_text))
    usage = Process.get(:responses_usage)
    calls = Process.get(:responses_calls)

    case result do
      :ok ->
        completed =
          shell(response_id, model_name(model), "completed", [
            message(message_id, "completed", [text_part(text)])
            | Enum.map(calls, &function_call_item(&1, "completed"))
          ])
          |> Map.put("usage", usage_view(usage))

        emit.("response.output_text.done", Map.put(base, "text", text))
        emit.("response.content_part.done", Map.put(base, "part", text_part(text)))

        emit.("response.output_item.done", %{
          "output_index" => 0,
          "item" => message(message_id, "completed", [text_part(text)])
        })

        emit.("response.completed", %{"response" => completed})

      {:error, reason} ->
        failed =
          started
          |> Map.put("status", "failed")
          |> Map.put("error", %{
            "code" => "provider_failed",
            "message" => "the provider did not finish: #{inspect(reason)}"
          })

        emit.("response.failed", %{"response" => failed})
    end

    Process.get(:responses_conn)
  end

  # ── non-streaming ────────────────────────────────────────────────────────

  defp collect(conn, model, request) do
    parent = self()

    result =
      model.adapter.stream(request, fn event -> send(parent, {:responses_event, event}) end)

    events = drain([])

    text =
      events
      |> Enum.map(fn
        {:text_delta, delta} -> delta
        _other -> ""
      end)
      |> IO.iodata_to_binary()

    usage =
      Enum.find_value(events, %{}, fn
        {:usage, map} when is_map(map) -> map
        _other -> nil
      end)

    calls =
      Enum.flat_map(events, fn
        {:tool_call, call} -> [call]
        _other -> []
      end)

    case result do
      :ok ->
        response_id = "resp_" <> identifier()
        message_id = "msg_" <> identifier()

        json(
          conn,
          shell(response_id, model_name(model), "completed", [
            message(message_id, "completed", [text_part(text)])
            | Enum.map(calls, &function_call_item(&1, "completed"))
          ])
          |> Map.put("usage", usage_view(usage))
        )

      {:error, reason} ->
        json(
          conn,
          shell("resp_" <> identifier(), model_name(model), "failed", [])
          |> Map.put("error", %{
            "code" => "provider_failed",
            "message" => "the provider did not answer: #{inspect(reason)}"
          })
        )
    end
  end

  defp drain(acc) do
    receive do
      {:responses_event, event} -> drain([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ── the response object ──────────────────────────────────────────────────

  defp shell(id, model_name, status, output) do
    %{
      "id" => id,
      "object" => "response",
      "created_at" => System.os_time(:second),
      "status" => status,
      "model" => model_name,
      "output" => output,
      "error" => nil,
      "usage" => %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}
    }
  end

  defp message(id, status, content) do
    %{
      "type" => "message",
      "id" => id,
      "role" => "assistant",
      "status" => status,
      "content" => content
    }
  end

  # One function_call output item, in the specification's shape. The
  # arguments are the raw JSON string the model produced; this surface
  # replays, never interprets.
  defp function_call_item(call, status) do
    %{
      "type" => "function_call",
      "id" => "fc_" <> identifier(),
      "call_id" => call.call_id,
      "name" => call.name,
      "arguments" => call.raw_arguments,
      "status" => status
    }
  end

  defp usage_view(usage) do
    input = whole(usage["input_tokens"])
    output = whole(usage["output_tokens"])

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => whole(usage["total_tokens"]) || (input || 0) + (output || 0)
    }
    |> Map.new(fn {key, value} -> {key, value || 0} end)
  end

  defp whole(value) when is_integer(value) and value >= 0, do: value
  defp whole(_value), do: nil

  defp text_part(text),
    do: %{"type" => "output_text", "text" => text, "annotations" => []}

  defp model_name(model), do: model.id

  defp identifier, do: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
end
