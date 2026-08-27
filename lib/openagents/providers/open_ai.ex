defmodule OpenAgents.Providers.OpenAI do
  @moduledoc """
  OpenAI Responses API adapter.

  OpenAI HTTP, SSE, and event shapes terminate here. Callers receive only
  `OpenAgents.Providers.ProviderEvent` values and normalized failure reasons.
  """

  @behaviour OpenAgents.Providers.Provider

  alias OpenAgents.Providers.OpenAI.StreamDecoder
  alias OpenAgents.Providers.{Request, ToolDefinition, ToolOutput}

  @endpoint "https://api.openai.com/v1/responses"

  @impl true
  def id, do: "openai.responses"

  @impl true
  def capabilities, do: [:text, :tool_calls, :usage]

  @impl true
  def configured? do
    match?({:ok, _key}, OpenAgents.RuntimeConfig.fetch_secret(:openai_api_key))
  end

  @impl true
  def stream(%Request{} = request, on_event) when is_function(on_event, 1) do
    stream(request, on_event, [])
  end

  @doc false
  def stream(%Request{} = request, on_event, options)
      when is_function(on_event, 1) and is_list(options) do
    with {:ok, api_key} <- fetch_api_key(options),
         {:ok, response} <- request(api_key, request, options) do
      consume_response(response, on_event)
    end
  end

  defp fetch_api_key(options) do
    case Keyword.fetch(options, :api_key) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 ->
        {:ok, key}

      _not_supplied ->
        case OpenAgents.RuntimeConfig.fetch_secret(:openai_api_key) do
          {:ok, key} -> {:ok, key}
          {:error, :not_configured} -> {:error, :missing_api_key}
        end
    end
  end

  defp request(api_key, %Request{} = request, options) do
    payload = request_payload(request)
    request_options = Keyword.get(options, :request_options, [])

    base_options = [
      auth: {:bearer, api_key},
      headers: [{"accept", "text/event-stream"}],
      json: payload,
      into: :self,
      receive_timeout: 120_000,
      retry: false
    ]

    case Req.post(@endpoint, Keyword.merge(base_options, request_options)) do
      {:ok, response} ->
        {:ok, response}

      {:error, %Req.TransportError{reason: reason}} when is_atom(reason) ->
        {:error, {:transport, reason}}

      {:error, _error} ->
        {:error, {:transport, :request_failed}}
    end
  end

  @doc false
  def request_payload(request) do
    %{
      model: request.model_id,
      instructions: request.instructions,
      input: input_items(request),
      tools: Enum.map(request.tool_definitions, &tool_definition/1),
      parallel_tool_calls: false,
      max_output_tokens: request.max_output,
      stream: true
    }
    |> maybe_put(:previous_response_id, request.previous_response_id)
  end

  # A serial continuation names the response it answers, so the outputs are
  # the whole input: the provider already holds the transcript.
  defp input_items(%Request{previous_response_id: id} = request) when is_binary(id) do
    case request.tool_outputs do
      [] -> Enum.map(request.input, &message_item/1)
      outputs -> Enum.map(outputs, &tool_output/1)
    end
  end

  # Without a previous response the transcript travels in full, so a prior
  # assistant tool call is replayed as its `function_call` item followed by
  # the `function_call_output` that answers it — an output without its call
  # is an item the Responses API refuses. An output whose call the caller
  # did not replay is appended last rather than dropped.
  defp input_items(%Request{} = request) do
    outputs_by_call_id = Map.new(request.tool_outputs, &{&1.call_id, &1})

    replayed_call_ids =
      request.input
      |> Enum.flat_map(&Map.get(&1, :tool_calls, []))
      |> MapSet.new(& &1.call_id)

    orphaned = Enum.reject(request.tool_outputs, &MapSet.member?(replayed_call_ids, &1.call_id))

    items = Enum.flat_map(request.input, &items_for_message(&1, outputs_by_call_id))
    items ++ Enum.map(orphaned, &tool_output/1)
  end

  defp items_for_message(%{tool_calls: [_call | _rest] = calls} = message, outputs_by_call_id) do
    prose = if message.content == "", do: [], else: [message_item(message)]

    calls
    |> Enum.flat_map(fn call ->
      output_items =
        case Map.fetch(outputs_by_call_id, call.call_id) do
          {:ok, output} -> [tool_output(output)]
          :error -> []
        end

      [function_call_item(call) | output_items]
    end)
    |> then(&(prose ++ &1))
  end

  defp items_for_message(message, _outputs_by_call_id), do: [message_item(message)]

  defp message_item(%{content: content} = message) when is_list(content) do
    %{role: message.role, content: Enum.map(content, &response_content_part/1)}
  end

  defp message_item(message), do: %{role: message.role, content: message.content}

  defp response_content_part(%{type: "text", text: text}),
    do: %{type: "input_text", text: text}

  defp response_content_part(%{type: "image_url", image_url: %{url: url}}),
    do: %{type: "input_image", image_url: url}

  defp function_call_item(call) do
    %{
      type: "function_call",
      call_id: call.call_id,
      name: call.name,
      arguments: call.arguments
    }
  end

  defp tool_definition(%ToolDefinition{} = definition) do
    %{
      type: "function",
      name: definition.name,
      description: definition.description,
      parameters: definition.input_schema,
      strict: definition.strict
    }
  end

  defp tool_output(%ToolOutput{} = output) do
    %{
      type: "function_call_output",
      call_id: output.call_id,
      output: Jason.encode!(output.output)
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp consume_response(%Req.Response{status: status, body: body}, on_event)
       when status in 200..299 do
    body
    |> Enum.reduce_while({:ok, StreamDecoder.new()}, fn chunk, {:ok, decoder} ->
      case StreamDecoder.feed(decoder, chunk) do
        {:ok, next_decoder, events} ->
          emit(events, on_event)
          {:cont, {:ok, next_decoder}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> finish(on_event)
  rescue
    _exception -> {:error, {:transport, :stream_failed}}
  end

  defp consume_response(%Req.Response{status: status}, _on_event),
    do: {:error, {:http_status, status}}

  defp finish({:ok, decoder}, on_event) do
    case StreamDecoder.finish(decoder) do
      {:ok, _decoder, events} ->
        emit(events, on_event)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish({:error, reason}, _on_event), do: {:error, reason}

  defp emit(events, on_event), do: Enum.each(events, on_event)
end
