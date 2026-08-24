defmodule OpenAgents.Providers.OpenRouter do
  @moduledoc """
  OpenRouter chat-completions adapter for the inference proxy.

  This is the second provider the proxy can reach, and it exists so a grant can
  pin Ox Alpha: `OpenAgents.Inference.Models` names which model each provider
  serves, and the proxy dispatches on the grant's model rather than on one
  compiled-in module.

  OpenRouter HTTP, SSE framing, and chat-completions shapes terminate here.
  Callers receive only `OpenAgents.Providers.ProviderEvent` values and
  normalized failure reasons, and the OpenRouter credential never leaves the
  server (RELEASE-002).

  The chat-completions surface is used rather than the Responses surface the
  `/chat` console prefers, because a proxy request arrives as OpenAI-style
  messages from a harness and chat completions is the shape that maps to it
  without a second translation.
  """

  @behaviour OpenAgents.Providers.Provider

  alias OpenAgents.Providers.OpenRouter.StreamDecoder
  alias OpenAgents.Providers.{Request, ToolDefinition, ToolOutput}

  @endpoint "https://openrouter.ai/api/v1/chat/completions"

  @impl true
  def id, do: "openrouter.chat_completions"

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
        case OpenAgents.RuntimeConfig.fetch_secret(:openrouter_api_key) do
          {:ok, key} -> {:ok, key}
          {:error, :not_configured} -> {:error, :missing_api_key}
        end
    end
  end

  defp request(api_key, %Request{} = request, options) do
    request_options = Keyword.get(options, :request_options, [])

    base_options = [
      auth: {:bearer, api_key},
      headers: [{"accept", "text/event-stream"}],
      json: request_payload(request),
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
  def request_payload(%Request{} = request) do
    %{
      model: request.model_id,
      messages: messages(request),
      stream: true,
      stream_options: %{include_usage: true},
      max_tokens: 4_096
    }
    |> maybe_put_tools(request.tool_definitions)
  end

  # The proxy hands over the system text separately from the turns. A tool
  # output whose assistant call is in the transcript is carried faithfully as
  # a `tool` role message right after the assistant turn that called it. An
  # output without that call — a harness that flattens its own tool loop
  # before it sends — is carried as a labelled user message instead: it keeps
  # the result in the transcript without claiming a call OpenRouter never saw.
  defp messages(%Request{} = request) do
    instructions =
      case String.trim(request.instructions || "") do
        "" -> []
        text -> [%{role: "system", content: text}]
      end

    declared_call_ids =
      request.input
      |> Enum.flat_map(&Map.get(&1, :tool_calls, []))
      |> MapSet.new(& &1.call_id)

    {matched, orphaned} =
      Enum.split_with(request.tool_outputs, &MapSet.member?(declared_call_ids, &1.call_id))

    outputs_by_call_id = Map.new(matched, &{&1.call_id, &1})

    turns = Enum.flat_map(request.input, &turn(&1, outputs_by_call_id))
    instructions ++ turns ++ Enum.map(orphaned, &orphaned_tool_output/1)
  end

  defp turn(%{tool_calls: [_call | _rest] = calls} = message, outputs_by_call_id) do
    assistant = %{
      role: "assistant",
      content: message.content,
      tool_calls: Enum.map(calls, &assistant_tool_call/1)
    }

    results =
      calls
      |> Enum.flat_map(fn call ->
        case Map.fetch(outputs_by_call_id, call.call_id) do
          {:ok, output} -> [tool_result(output)]
          :error -> []
        end
      end)

    [assistant | results]
  end

  defp turn(message, _outputs_by_call_id),
    do: [%{role: role(message.role), content: message.content}]

  defp role(role) when role in ["system", "user", "assistant"], do: role
  defp role(_role), do: "user"

  defp assistant_tool_call(call) do
    %{
      id: call.call_id,
      type: "function",
      function: %{name: call.name, arguments: call.arguments}
    }
  end

  defp tool_result(%ToolOutput{} = output) do
    %{
      role: "tool",
      tool_call_id: output.call_id,
      content: Jason.encode!(output.output)
    }
  end

  defp orphaned_tool_output(%ToolOutput{} = output) do
    %{
      role: "user",
      content: "Tool result for #{output.call_id}: #{Jason.encode!(output.output)}"
    }
  end

  defp maybe_put_tools(payload, []), do: payload

  defp maybe_put_tools(payload, definitions) do
    Map.put(payload, :tools, Enum.map(definitions, &tool_definition/1))
  end

  defp tool_definition(%ToolDefinition{} = definition) do
    %{
      type: "function",
      function: %{
        name: definition.name,
        description: definition.description,
        parameters: definition.input_schema
      }
    }
  end

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
