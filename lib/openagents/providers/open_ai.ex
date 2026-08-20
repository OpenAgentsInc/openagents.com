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
    input =
      case request.tool_outputs do
        [] -> request.input
        outputs -> Enum.map(outputs, &tool_output/1)
      end

    %{
      model: request.model_id,
      instructions: request.instructions,
      input: input,
      tools: Enum.map(request.tool_definitions, &tool_definition/1),
      parallel_tool_calls: false,
      max_output_tokens: 4_096,
      stream: true
    }
    |> maybe_put(:previous_response_id, request.previous_response_id)
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
