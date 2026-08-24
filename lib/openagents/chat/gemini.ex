defmodule OpenAgents.Chat.Gemini do
  @moduledoc """
  Server-side Google Gemini adapter for the `/chat` console and the chat API.

  This adapter answers the same `stream/3` contract as
  `OpenAgents.Chat.OpenRouter` and returns the same completion map, so a turn
  runs through one pipeline whichever backend produced it and no client learns
  a second vocabulary. The credential and the transport stay on the server: the
  model is billed to the OpenAgents Google balance, so a caller spends nothing
  to use it and never holds a key that could be spent elsewhere.

  Three things about the Gemini wire format are absorbed here rather than
  leaking outward.

  The model is a path segment, not a body field, and streaming requires
  `?alt=sse` — without it the endpoint answers with one JSON array instead of a
  stream. Roles are `user` and `model`; Gemini has no `assistant`, and a system
  message is not a message at all but the separate `systemInstruction` field,
  so system turns are hoisted out of the transcript rather than relabelled.

  Reasoning is requested explicitly. `thinkingConfig.includeThoughts` is what
  makes Gemini return the reasoning *text* rather than only counting it, and
  without it a turn reports hundreds of thinking tokens the console can show a
  number for but no content for. The console already renders reasoning, so this
  adapter asks for it and `OpenAgents.Chat.Gemini.StreamDecoder` separates it
  from the answer.
  """

  alias OpenAgents.Chat.Gemini.StreamDecoder

  # Vertex Express, not the Generative Language endpoint. The two speak the same
  # `generateContent` request and response, and take the same API key, but the
  # key this deployment holds is authorized for one of them: Generative
  # Language answers `PERMISSION_DENIED` for every method, including
  # `ListModels`, under both the query parameter and the `x-goog-api-key`
  # header. Vertex Express answers normally, streams over `?alt=sse`, and
  # returns the `thought: true` parts the decoder splits on.
  @endpoint "https://aiplatform.googleapis.com/v1/publishers/google/models"
  @default_model "gemini-3.7-flash"
  @model_label "Gemini 3.7 Flash"
  @maximum_output_tokens 8192

  @type completion :: map()
  @type failure ::
          :missing_api_key
          | :rate_limited
          | :provider_unavailable
          | :service_unavailable
          | :stream_interrupted
          | :invalid_response

  @doc "The Gemini model this adapter requests unless configuration names another."
  @spec default_model() :: String.t()
  def default_model, do: Application.get_env(:openagents, :gemini_model, @default_model)

  @doc "The label the console shows for this backend."
  @spec model_label() :: String.t()
  def model_label, do: @model_label

  @doc """
  Streams one Gemini turn, emitting the events every backend here emits.

  `request` is the provider-neutral map the turn runtime builds: `"model"`,
  `"messages"`, and `"reasoning"`. The callback receives `{:text_delta, _}` and
  `{:reasoning_delta, _}` exactly as the OpenRouter adapter emits them.
  """
  @spec stream(map(), (tuple() -> any()), keyword()) :: {:ok, completion()} | {:error, failure()}
  def stream(request, on_event, options \\ [])
      when is_map(request) and is_function(on_event, 1) and is_list(options) do
    with {:ok, api_key} <- fetch_api_key(options),
         {:ok, model} <- fetch_model(request),
         {:ok, payload} <- payload(request),
         {:ok, response} <- stream_request(api_key, model, payload, options) do
      consume_stream(response, on_event, model)
    end
  end

  defp fetch_api_key(options) do
    case Keyword.fetch(options, :api_key) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 ->
        {:ok, key}

      _not_supplied ->
        case OpenAgents.RuntimeConfig.fetch_secret(:gemini_api_key) do
          {:ok, key} -> {:ok, key}
          {:error, :not_configured} -> {:error, :missing_api_key}
        end
    end
  end

  defp fetch_model(%{"model" => model}) when is_binary(model) and byte_size(model) in 1..128,
    do: {:ok, model}

  defp fetch_model(_request), do: {:ok, default_model()}

  @doc false
  @spec payload(map()) :: {:ok, map()} | {:error, :invalid_response}
  def payload(%{"messages" => messages} = request) when is_list(messages) do
    {system, turns} = Enum.split_with(messages, &system_message?/1)

    case contents(turns) do
      {:ok, []} ->
        {:error, :invalid_response}

      {:ok, contents} ->
        {:ok,
         %{"contents" => contents, "generationConfig" => generation_config(request)}
         |> put_system_instruction(system)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def payload(_request), do: {:error, :invalid_response}

  defp system_message?(%{"role" => "system"}), do: true
  defp system_message?(_message), do: false

  defp contents(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, contents} ->
      case content(message) do
        {:ok, nil} -> {:cont, {:ok, contents}}
        {:ok, entry} -> {:cont, {:ok, contents ++ [entry]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Gemini names the two sides `user` and `model`. Sending `assistant` is a
  # rejected request, not a tolerated synonym.
  defp content(%{"role" => role, "content" => text})
       when is_binary(role) and is_binary(text) do
    if text == "" do
      {:ok, nil}
    else
      {:ok, %{"role" => gemini_role(role), "parts" => [%{"text" => text}]}}
    end
  end

  defp content(_message), do: {:error, :invalid_response}

  defp gemini_role(role) when role in ["assistant", "model"], do: "model"
  defp gemini_role(_role), do: "user"

  defp put_system_instruction(payload, []), do: payload

  defp put_system_instruction(payload, system) do
    parts =
      system
      |> Enum.map(&Map.get(&1, "content"))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.map(&%{"text" => &1})

    if parts == [],
      do: payload,
      else: Map.put(payload, "systemInstruction", %{"parts" => parts})
  end

  # `includeThoughts` is what turns the reasoning from a token count into text
  # the transcript can show. Gemini 3.x replaced the numeric thinking budget
  # with a level, so the console's effort maps onto that vocabulary and the
  # deprecated sampling knobs are not sent at all.
  defp generation_config(request) do
    config = %{
      "maxOutputTokens" => @maximum_output_tokens,
      "thinkingConfig" => %{"includeThoughts" => true}
    }

    case thinking_level(request["reasoning"]) do
      nil -> config
      level -> put_in(config, ["thinkingConfig", "thinkingLevel"], level)
    end
  end

  # `minimal` is a documented level this model refuses ("Thinking level MINIMAL
  # is not supported for this model"), so the two efforts below `low` map onto
  # `low` rather than onto a name that would fail the request.
  defp thinking_level("none"), do: "low"
  defp thinking_level("minimal"), do: "low"
  defp thinking_level("low"), do: "low"
  defp thinking_level("medium"), do: "medium"
  defp thinking_level("high"), do: "high"
  defp thinking_level("max"), do: "high"
  defp thinking_level(_effort), do: nil

  defp stream_request(api_key, model, payload, options) do
    request_options = Keyword.get(options, :request_options, [])

    request = [
      headers: [
        {"x-goog-api-key", api_key},
        {"accept", "text/event-stream"},
        {"content-type", "application/json"}
      ],
      json: payload,
      into: :self,
      receive_timeout: 120_000,
      retry: false
    ]

    url = "#{@endpoint}/#{model}:streamGenerateContent?alt=sse"

    case Req.post(url, Keyword.merge(request, request_options)) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{} = response} ->
        {:error, status_failure(response)}

      {:error, _reason} ->
        {:error, :provider_unavailable}
    end
  end

  defp status_failure(%Req.Response{status: 429}), do: :rate_limited

  defp status_failure(%Req.Response{status: status}) when status in [500, 502, 503, 504],
    do: :service_unavailable

  defp status_failure(%Req.Response{}), do: :provider_unavailable

  defp consume_stream(%Req.Response{body: %Req.Response.Async{} = body}, on_event, model) do
    body
    |> Enum.reduce_while({:ok, StreamDecoder.new(model: model)}, fn chunk, {:ok, state} ->
      case StreamDecoder.feed(state, chunk) do
        {:ok, state, events} ->
          Enum.each(events, on_event)
          {:cont, {:ok, state}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> finish_stream()
  rescue
    _exception -> {:error, :stream_interrupted}
  end

  defp consume_stream(%Req.Response{}, _on_event, _model), do: {:error, :invalid_response}

  defp finish_stream({:ok, state}), do: StreamDecoder.finish(state)
  defp finish_stream({:error, reason}), do: {:error, reason}
end
