defmodule OpenAgents.Chat.OpenRouter do
  @moduledoc """
  Server-side OpenRouter Responses adapter for the `/chat` console.

  The adapter keeps the OpenRouter credential and HTTP transport on the server.
  It requests GLM 5.3 Flash and uses chat completions only when a provider does
  not support Responses. It returns normalized failures without provider
  credentials or response bodies, and it separates the failures an operator can
  retry — a rate limit, an unavailable provider, an interrupted stream, and a
  malformed stream — from the ones a retry cannot fix.
  """

  alias OpenAgents.Chat.OpenRouter.{ResponsesStreamDecoder, ToolRuntime}

  @chat_completions_endpoint "https://openrouter.ai/api/v1/chat/completions"
  @responses_endpoint "https://openrouter.ai/api/v1/responses"
  # `stealth/ox-alpha` was GLM 5.3 Flash under its pre-launch name; OpenRouter
  # answers that slug with a 404 now. Note the hyphen: OpenRouter writes the
  # creator `z-ai` and the Vercel gateway writes it `zai`.
  @default_model "z-ai/glm-5.3-flash"
  @model_label "GLM 5.3 Flash"
  @maximum_tool_rounds 6
  @tool_instructions """
  Ground every repository claim in repository tool output. Never claim that a file or directory exists unless a tool result confirms it. Use list_repository_directory before guessing a path, and use the returned paths exactly. Do not retry the same failed repository, path, and ref combination. If a read fails, list its parent directory once or tell the user that the requested content is unavailable.
  """
  @reasoning_efforts ~w(none minimal low medium high max)

  @type completion :: map()
  @type failure ::
          :missing_api_key
          | :rate_limited
          | :provider_unavailable
          | :service_unavailable
          | :stream_interrupted
          | :invalid_response
          | {:provider_error, String.t(), String.t() | nil}

  @spec complete(map(), keyword()) :: {:ok, completion()} | {:error, failure()}
  def complete(request, options \\ []) when is_map(request) and is_list(options) do
    with {:ok, api_key} <- fetch_api_key(options),
         {:ok, response} <- request(api_key, request, options),
         {:ok, completion} <- decode_response(response) do
      {:ok, completion}
    end
  end

  @spec stream(map(), (tuple() -> any()), keyword()) :: {:ok, completion()} | {:error, failure()}
  def stream(request, on_event, options \\ [])
      when is_map(request) and is_function(on_event, 1) and is_list(options) do
    with {:ok, api_key} <- fetch_api_key(options) do
      stream_with_responses_fallback(api_key, request, on_event, options)
    end
  end

  @doc false
  def default_model, do: Application.get_env(:openagents, :openrouter_model, @default_model)

  @doc "The fixed label the console shows for the configured model."
  def model_label, do: @model_label

  @doc false
  def reasoning_effort(value) when value in @reasoning_efforts, do: value
  def reasoning_effort(_value), do: "high"

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

  defp request(api_key, request, options) do
    request_options = Keyword.get(options, :request_options, [])

    options = [
      auth: {:bearer, api_key},
      headers: attribution_headers("application/json"),
      json: request,
      receive_timeout: 60_000,
      retry: false
    ]

    case Req.post(@chat_completions_endpoint, Keyword.merge(options, request_options)) do
      {:ok, response} -> {:ok, response}
      {:error, _reason} -> {:error, :provider_unavailable}
    end
  end

  defp stream_with_responses_fallback(api_key, request, on_event, options) do
    with {:ok, tool_runtime} <- ToolRuntime.capture(options),
         {:ok, payload} <- responses_payload(request, tool_runtime) do
      case responses_stream_request(api_key, payload, options) do
        {:ok, response} -> consume_responses_stream(response, on_event, payload["model"])
        {:fallback, _reason} -> stream_with_chat_completions(api_key, request, on_event, options)
        {:error, reason} -> {:error, reason}
      end
      |> continue_responses_tool_calls(
        api_key,
        payload,
        on_event,
        options,
        tool_runtime,
        @maximum_tool_rounds
      )
    else
      {:error, :responses_history_unavailable} ->
        stream_with_chat_completions(api_key, request, on_event, options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp responses_stream_request(api_key, payload, options) do
    request_options = Keyword.get(options, :request_options, [])

    options = [
      auth: {:bearer, api_key},
      headers: stream_headers(),
      json: Map.put(payload, "stream", true),
      into: :self,
      receive_timeout: 120_000,
      retry: false
    ]

    case Req.post(@responses_endpoint, Keyword.merge(options, request_options)) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status}} when status in [404, 405] ->
        {:fallback, :responses_api_unavailable}

      {:ok, %Req.Response{} = response} ->
        {:error, provider_failure(response)}

      {:error, _reason} ->
        {:error, :provider_unavailable}
    end
  end

  defp stream_with_chat_completions(api_key, request, on_event, options) do
    with {:ok, response} <- chat_stream_request(api_key, chat_request(request), options),
         {:ok, completion} <- consume_stream(response, on_event) do
      {:ok, completion}
    end
  end

  defp responses_payload(%{"model" => model, "messages" => messages} = request, tool_runtime)
       when is_binary(model) and is_list(messages) do
    with {:ok, input} <- responses_input(messages) do
      payload = %{"model" => model, "input" => input}

      payload =
        case Map.get(request, "models") do
          models when is_list(models) and models != [] -> Map.put(payload, "models", models)
          _otherwise -> payload
        end

      reasoning =
        request
        |> Map.get("reasoning")
        |> reasoning_effort()
        |> reasoning_request()

      {:ok,
       Map.merge(payload, %{
         "instructions" => @tool_instructions,
         "tools" => ToolRuntime.provider_definitions(tool_runtime, latest_user_intent(messages)),
         "tool_choice" => "auto",
         "reasoning" => reasoning,
         "include" => ["reasoning.encrypted_content"],
         "max_output_tokens" => 9_000
       })}
    end
  end

  defp responses_payload(_request, _tool_runtime), do: {:error, :invalid_response}

  defp latest_user_intent(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{"role" => "user", "content" => content} when is_binary(content) -> content
      _message -> nil
    end)
  end

  defp reasoning_request("none"), do: %{"effort" => "none", "exclude" => false}

  defp reasoning_request(effort),
    do: %{"effort" => effort, "exclude" => false, "summary" => "detailed"}

  defp responses_input(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, input} ->
      case response_input_items(message) do
        {:ok, items} -> {:cont, {:ok, input ++ items}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp response_input_items(%{"role" => "user", "content" => content}) when is_binary(content) do
    {:ok,
     [
       %{
         "type" => "message",
         "role" => "user",
         "content" => [%{"type" => "input_text", "text" => content}]
       }
     ]}
  end

  defp response_input_items(%{"role" => "assistant", "provider_output" => output})
       when is_list(output),
       do: {:ok, output}

  defp response_input_items(
         %{
           "role" => "assistant",
           "content" => content,
           "id" => id,
           "status" => "completed"
         } = message
       )
       when is_binary(content) and is_binary(id) do
    {:ok,
     response_reasoning_items(message["reasoning_items"]) ++
       [
         %{
           "type" => "message",
           "role" => "assistant",
           "id" => id,
           "status" => "completed",
           "content" => [%{"type" => "output_text", "text" => content, "annotations" => []}]
         }
       ]}
  end

  defp response_input_items(%{"role" => "assistant"}),
    do: {:error, :responses_history_unavailable}

  defp response_input_items(_message), do: {:error, :invalid_response}

  defp response_reasoning_items(items) when is_list(items) do
    Enum.filter(items, &reasoning_item?/1)
  end

  defp response_reasoning_items(_items), do: []

  defp reasoning_item?(%{"type" => "reasoning", "id" => id, "encrypted_content" => content})
       when is_binary(id) and is_binary(content),
       do: true

  defp reasoning_item?(_item), do: false

  defp chat_request(%{"model" => model, "messages" => messages} = request)
       when is_binary(model) and is_list(messages) do
    request
    |> Map.take(["model", "models"])
    |> Map.put("messages", Enum.map(messages, &Map.take(&1, ["role", "content"])))
  end

  defp chat_request(request), do: request

  defp continue_responses_tool_calls(
         {:ok, %{"tool_calls" => tool_calls, "output" => provider_output} = completion},
         api_key,
         payload,
         on_event,
         options,
         tool_runtime,
         rounds_remaining
       )
       when is_list(tool_calls) and is_list(provider_output) and rounds_remaining > 0 do
    with {:ok, tool_outputs} <- execute_tool_calls(tool_calls, on_event, tool_runtime),
         payload <- Map.update!(payload, "input", &(&1 ++ provider_output ++ tool_outputs)),
         {:ok, response} <- responses_stream_request(api_key, payload, options),
         result <- consume_responses_stream(response, on_event, payload["model"]) do
      result
      |> carry_earlier_round(completion)
      |> continue_responses_tool_calls(
        api_key,
        payload,
        on_event,
        options,
        tool_runtime,
        rounds_remaining - 1
      )
    end
  end

  defp continue_responses_tool_calls(
         {:ok, %{"tool_calls" => _tool_calls}},
         _api_key,
         _payload,
         _on_event,
         _options,
         _tool_runtime,
         0
       ),
       do: {:error, :invalid_response}

  defp continue_responses_tool_calls(
         result,
         _api_key,
         _payload,
         _on_event,
         _options,
         _tool_runtime,
         _rounds_remaining
       ),
       do: result

  # A turn spends one provider request per tool round, and each response reports
  # only what that round consumed and reasoned. Carrying the earlier round's
  # evidence forward keeps the whole turn in the completion the console stores,
  # so a turn that reasoned before calling a tool still shows that it reasoned.
  defp carry_earlier_round({:ok, completion}, earlier) when is_map(earlier) do
    {:ok,
     completion
     |> carry_usage(Map.get(earlier, "usage"))
     |> carry_reasoning_summary(Map.get(earlier, "reasoning_summary"))}
  end

  defp carry_earlier_round(result, _earlier), do: result

  defp carry_usage(completion, earlier) when is_map(earlier),
    do: Map.put(completion, "usage", add_usage(Map.get(completion, "usage"), earlier))

  defp carry_usage(completion, _earlier), do: completion

  # Only the summary carries. The encrypted reasoning items replay to the
  # provider on the next turn, and an intermediate round's items belong to the
  # tool exchange that consumed them.
  defp carry_reasoning_summary(completion, earlier) when is_binary(earlier) and earlier != "" do
    case Map.get(completion, "reasoning_summary") do
      summary when is_binary(summary) and summary != "" ->
        Map.put(completion, "reasoning_summary", earlier <> "\n\n" <> summary)

      _absent ->
        Map.put(completion, "reasoning_summary", earlier)
    end
  end

  defp carry_reasoning_summary(completion, _earlier), do: completion

  # A count no round reported stays absent instead of becoming a zero.
  defp add_usage(usage, earlier) when is_map(usage) and is_map(earlier),
    do:
      Map.merge(usage, earlier, fn _key, value, earlier_value ->
        add_count(value, earlier_value)
      end)

  defp add_usage(nil, earlier), do: earlier
  defp add_usage(usage, _earlier), do: usage

  defp add_count(value, earlier) when is_number(value) and is_number(earlier),
    do: value + earlier

  defp add_count(value, earlier) when is_map(value) and is_map(earlier),
    do: add_usage(value, earlier)

  defp add_count(value, _earlier), do: value

  defp execute_tool_calls(tool_calls, on_event, tool_runtime) do
    result =
      Enum.reduce_while(tool_calls, [], fn %{
                                             "call_id" => call_id,
                                             "name" => name,
                                             "arguments" => arguments
                                           },
                                           outputs ->
        on_event.(
          {:tool_call_started, %{"call_id" => call_id, "name" => name, "arguments" => arguments}}
        )

        case ToolRuntime.run(tool_runtime, call_id, name, arguments) do
          {:ok, %{"status" => "succeeded"} = outcome} ->
            encoded_output = Jason.encode!(outcome)
            on_event.({:tool_call_completed, %{"call_id" => call_id, "output" => encoded_output}})

            output = %{
              "type" => "function_call_output",
              "call_id" => call_id,
              "output" => encoded_output
            }

            {:cont, [output | outputs]}

          {:ok, outcome} ->
            error = get_in(outcome, ["error", "message"]) || "The tool call failed."
            on_event.({:tool_call_failed, %{"call_id" => call_id, "error" => error}})

            output = %{
              "type" => "function_call_output",
              "call_id" => call_id,
              "output" => Jason.encode!(outcome)
            }

            {:cont, [output | outputs]}

          {:error, _error} ->
            {:halt, {:error, :invalid_response}}
        end
      end)

    case result do
      {:error, reason} -> {:error, reason}
      outputs -> {:ok, Enum.reverse(outputs)}
    end
  rescue
    _exception -> {:error, :invalid_response}
  end

  defp chat_stream_request(api_key, request, options) do
    request_options = Keyword.get(options, :request_options, [])

    options = [
      auth: {:bearer, api_key},
      headers: stream_headers(),
      json: Map.put(request, "stream", true),
      into: :self,
      receive_timeout: 120_000,
      retry: false
    ]

    case Req.post(@chat_completions_endpoint, Keyword.merge(options, request_options)) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %Req.Response{} = response} -> {:error, provider_failure(response)}
      {:error, _reason} -> {:error, :provider_unavailable}
    end
  end

  defp stream_headers do
    attribution_headers("text/event-stream")
  end

  defp attribution_headers(accept) do
    [
      {"accept", accept},
      {"http-referer", OpenAgentsWeb.Endpoint.url()},
      {"x-openrouter-title", "OpenAgents"},
      {"x-openrouter-categories", "cloud-agent,general-chat"}
    ]
  end

  defp consume_stream(%Req.Response{body: %Req.Response.Async{} = body}, on_event) do
    body
    |> Enum.reduce_while({:ok, empty_chat_stream_state()}, fn chunk, {:ok, state} ->
      case consume_chunk(state, chunk, on_event) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> finish_stream()
  rescue
    _exception -> {:error, :stream_interrupted}
  end

  defp consume_stream(%Req.Response{}, _on_event), do: {:error, :invalid_response}

  defp consume_responses_stream(
         %Req.Response{body: %Req.Response.Async{} = body},
         on_event,
         model
       ) do
    body
    |> Enum.reduce_while({:ok, ResponsesStreamDecoder.new(model: model)}, fn chunk,
                                                                             {:ok, state} ->
      case ResponsesStreamDecoder.feed(state, chunk) do
        {:ok, state, events} ->
          Enum.each(events, on_event)
          {:cont, {:ok, state}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> finish_responses_stream()
  rescue
    _exception -> {:error, :stream_interrupted}
  end

  defp consume_responses_stream(%Req.Response{}, _on_event, _model),
    do: {:error, :invalid_response}

  defp finish_responses_stream({:ok, state}), do: ResponsesStreamDecoder.finish(state)
  defp finish_responses_stream({:error, reason}), do: {:error, reason}

  defp consume_chunk(state, chunk, on_event) when is_binary(chunk) do
    buffer = String.replace(state.buffer <> chunk, "\r\n", "\n")

    if byte_size(buffer) > 262_144 do
      {:error, :invalid_response}
    else
      parts = String.split(buffer, "\n\n")
      {frames, [remainder]} = Enum.split(parts, -1)

      Enum.reduce_while(frames, {:ok, %{state | buffer: remainder}}, fn frame, {:ok, state} ->
        case consume_frame(state, frame, on_event) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp consume_frame(state, frame, on_event) do
    data =
      frame
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", &(String.replace_prefix(&1, "data:", "") |> String.trim_leading()))

    case data do
      "" -> {:ok, state}
      "[DONE]" -> {:ok, %{state | complete?: true}}
      json -> consume_event(state, Jason.decode(json), on_event)
    end
  end

  defp consume_event(_state, {:error, _reason}, _on_event), do: {:error, :invalid_response}

  defp consume_event(_state, {:ok, %{"error" => _error}}, _on_event),
    do: {:error, :provider_unavailable}

  defp consume_event(state, {:ok, %{} = event}, on_event) do
    with {:ok, state} <- capture_model(state, event["model"]),
         :ok <- emit_text_delta(event, on_event) do
      {:ok, capture_provider_metadata(state, event)}
    end
  end

  defp consume_event(_state, {:ok, _event}, _on_event), do: {:error, :invalid_response}

  defp capture_model(state, nil), do: {:ok, state}

  defp capture_model(state, model) when is_binary(model) and byte_size(model) in 1..256,
    do: {:ok, %{state | model: model}}

  defp capture_model(_state, _model), do: {:error, :invalid_response}

  # Provider-reported evidence only. A missing field stays missing rather than
  # becoming a guess the console would present as measured.
  defp capture_provider_metadata(state, event) do
    state
    |> put_metadata(:usage, event["usage"])
    |> put_metadata(:request_id, event["id"])
    |> put_metadata(:provider, event["provider"])
  end

  defp put_metadata(state, :usage, usage) when is_map(usage), do: %{state | usage: usage}

  defp put_metadata(state, key, value)
       when key in [:request_id, :provider] and is_binary(value) and byte_size(value) in 1..256,
       do: Map.put(state, key, value)

  defp put_metadata(state, _key, _value), do: state

  defp emit_text_delta(%{"choices" => choices}, on_event) when is_list(choices) do
    choices
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "index") == 0))
    |> Enum.reduce_while(:ok, fn choice, :ok ->
      case get_in(choice, ["delta", "content"]) do
        nil ->
          {:cont, :ok}

        delta when is_binary(delta) and byte_size(delta) <= 65_536 ->
          on_event.({:text_delta, delta})
          {:cont, :ok}

        _invalid ->
          {:halt, {:error, :invalid_response}}
      end
    end)
  end

  defp emit_text_delta(%{}, _on_event), do: :ok

  defp empty_chat_stream_state,
    do: %{
      buffer: "",
      complete?: false,
      model: nil,
      usage: nil,
      request_id: nil,
      provider: nil
    }

  defp finish_stream({:ok, %{complete?: true, model: model} = state}) when is_binary(model) do
    completion =
      %{"object" => "chat.completion", "model" => model}
      |> maybe_put("usage", state.usage)
      |> maybe_put("request_id", state.request_id)
      |> maybe_put("provider", state.provider)

    {:ok, completion}
  end

  defp finish_stream({:ok, _state}), do: {:error, :invalid_response}
  defp finish_stream({:error, reason}), do: {:error, reason}

  defp decode_response(%Req.Response{status: status, body: body})
       when status in 200..299 and is_map(body) do
    case body do
      %{
        "id" => id,
        "object" => "chat.completion",
        "model" => model,
        "choices" => [%{"message" => %{"role" => "assistant", "content" => content}} | _]
      }
      when is_binary(id) and is_binary(model) and is_binary(content) ->
        {:ok, body}

      _invalid ->
        {:error, :invalid_response}
    end
  end

  defp decode_response(%Req.Response{} = response), do: {:error, provider_failure(response)}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp provider_failure(%Req.Response{status: 429}), do: :rate_limited

  defp provider_failure(%Req.Response{status: status}) when status in [502, 503, 504],
    do: :service_unavailable

  defp provider_failure(%Req.Response{body: %Req.Response.Async{} = body}) do
    body
    |> async_error_body()
    |> provider_error()
  end

  defp provider_failure(%Req.Response{body: body}) when is_map(body) do
    provider_error(body)
  end

  defp provider_failure(%Req.Response{}), do: :provider_unavailable

  defp async_error_body(body) do
    body
    |> Enum.reduce_while("", fn chunk, buffer ->
      buffer = buffer <> chunk

      if byte_size(buffer) > 262_144 do
        {:halt, ""}
      else
        {:cont, buffer}
      end
    end)
    |> Jason.decode()
    |> case do
      {:ok, body} when is_map(body) -> body
      _invalid -> %{}
    end
  rescue
    _exception -> %{}
  end

  defp provider_error(body) do
    error =
      case Map.get(body, "error") do
        error when is_map(error) -> error
        _missing_or_invalid -> %{}
      end

    code = Map.get(body, "error_type") || Map.get(error, "code") || "provider_error"
    message = Map.get(error, "message")

    {:provider_error, normalize_error_code(code), normalize_error_message(message)}
  end

  defp normalize_error_code(code) when is_binary(code) do
    code
    |> String.trim()
    |> String.slice(0, 80)
    |> case do
      "" -> "provider_error"
      normalized -> normalized
    end
  end

  defp normalize_error_code(_code), do: "provider_error"

  defp normalize_error_message(message) when is_binary(message) do
    message
    |> String.trim()
    |> String.slice(0, 240)
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_error_message(_message), do: nil
end
