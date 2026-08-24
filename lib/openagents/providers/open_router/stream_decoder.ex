defmodule OpenAgents.Providers.OpenRouter.StreamDecoder do
  @moduledoc false

  alias OpenAgents.Providers.ProviderEvent.ToolCall

  @maximum_buffer_bytes 262_144
  @maximum_delta_bytes 65_536
  @maximum_arguments_bytes 65_536
  @identifier_regex ~r/\A[a-zA-Z0-9_.:\/-]+\z/
  @tool_name_regex ~r/\A[a-zA-Z0-9_-]+\z/

  defstruct buffer: "", response_id: nil, terminal?: false, failed?: false, calls: %{}

  @type t :: %__MODULE__{
          buffer: String.t(),
          response_id: String.t() | nil,
          terminal?: boolean(),
          failed?: boolean(),
          calls: %{optional(integer()) => map()}
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec feed(t(), binary()) ::
          {:ok, t(), [OpenAgents.Providers.ProviderEvent.t()]} | {:error, atom()}
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    buffer = String.replace(state.buffer <> chunk, "\r\n", "\n")

    if byte_size(buffer) > @maximum_buffer_bytes do
      {:error, :invalid_provider_event}
    else
      parts = String.split(buffer, "\n\n")
      {frames, [remainder]} = Enum.split(parts, -1)
      decode_frames(%{state | buffer: remainder}, frames)
    end
  end

  @doc """
  Close the stream.

  A chat-completions stream reports its end with a `finish_reason`, and the
  accumulated tool calls are only whole once that arrives, so they are emitted
  here rather than mid-stream. A stream that ends without one is truncated: the
  reply it carried is a fragment, and reporting it as complete would hand a
  caller half an answer as a whole one.

  A stream that already reported a failure is closed without a completion and
  without its part-built calls: the failure is the outcome, and a completion
  after it would say the reply arrived.
  """
  @spec finish(t()) :: {:ok, t(), [OpenAgents.Providers.ProviderEvent.t()]} | {:error, atom()}
  def finish(%__MODULE__{} = state) do
    with {:ok, state, events} <- decode_final_buffer(state, state.buffer) do
      cond do
        state.failed? -> {:ok, state, events}
        state.terminal? -> {:ok, state, events ++ completion_events(state)}
        true -> {:error, :truncated_stream}
      end
    end
  end

  defp completion_events(state) do
    tool_call_events(state) ++ [{:response_completed, id(state)}]
  end

  defp decode_final_buffer(state, buffer) do
    if String.trim(buffer) == "" do
      {:ok, %{state | buffer: ""}, []}
    else
      decode_frames(%{state | buffer: ""}, [buffer])
    end
  end

  defp decode_frames(state, frames) do
    Enum.reduce_while(frames, {:ok, state, []}, fn frame, {:ok, next_state, events} ->
      case decode_frame(next_state, frame) do
        {:ok, decoded_state, decoded_events} ->
          {:cont, {:ok, decoded_state, events ++ decoded_events}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_frame(state, frame) do
    data =
      frame
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", fn line ->
        line |> String.replace_prefix("data:", "") |> String.trim_leading()
      end)

    case data do
      "" -> {:ok, state, []}
      "[DONE]" -> {:ok, %{state | terminal?: true}, []}
      json -> decode_json(state, Jason.decode(json))
    end
  end

  defp decode_json(_state, {:error, _error}), do: {:error, :invalid_provider_event}

  defp decode_json(state, {:ok, %{"error" => error}}) when is_map(error) do
    {:ok, %{state | terminal?: true, failed?: true},
     [{:failed, {:provider_failed, error_code(error)}}]}
  end

  defp decode_json(state, {:ok, %{} = chunk}) do
    with {:ok, state, start_events} <- start_response(state, chunk["id"]),
         {:ok, state, choice_events} <- choices(state, chunk["choices"]),
         {:ok, usage_events} <- usage(chunk["usage"]) do
      {:ok, state, start_events ++ choice_events ++ usage_events}
    end
  end

  defp decode_json(_state, {:ok, _invalid}), do: {:error, :invalid_provider_event}

  defp choices(state, nil), do: {:ok, state, []}

  defp choices(state, choices) when is_list(choices) do
    Enum.reduce_while(choices, {:ok, state, []}, fn choice, {:ok, next_state, events} ->
      case choice(next_state, choice) do
        {:ok, decoded_state, decoded_events} ->
          {:cont, {:ok, decoded_state, events ++ decoded_events}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp choices(_state, _invalid), do: {:error, :invalid_provider_event}

  defp choice(state, %{} = choice) do
    delta = if is_map(choice["delta"]), do: choice["delta"], else: %{}
    state = if is_binary(choice["finish_reason"]), do: %{state | terminal?: true}, else: state

    with {:ok, text_events} <- text(delta["content"]),
         {:ok, state} <- tool_calls(state, delta["tool_calls"]) do
      {:ok, state, text_events}
    end
  end

  defp choice(_state, _invalid), do: {:error, :invalid_provider_event}

  defp text(nil), do: {:ok, []}
  defp text(""), do: {:ok, []}

  defp text(content) when is_binary(content) and byte_size(content) <= @maximum_delta_bytes,
    do: {:ok, [{:text_delta, content}]}

  defp text(_content), do: {:error, :invalid_provider_event}

  # A chat-completions tool call streams as fragments keyed by index: the name
  # arrives once and the arguments arrive as a string built up over chunks, so
  # the fragments are accumulated and emitted whole at the end of the stream.
  defp tool_calls(state, nil), do: {:ok, state}

  defp tool_calls(state, calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, state}, fn call, {:ok, next_state} ->
      case tool_call(next_state, call) do
        {:ok, decoded} -> {:cont, {:ok, decoded}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp tool_calls(_state, _invalid), do: {:error, :invalid_provider_event}

  defp tool_call(state, %{} = call) do
    index = if is_integer(call["index"]), do: call["index"], else: 0
    function = if is_map(call["function"]), do: call["function"], else: %{}
    held = Map.get(state.calls, index, %{id: nil, name: nil, arguments: ""})

    arguments =
      case function["arguments"] do
        fragment when is_binary(fragment) -> held.arguments <> fragment
        _absent -> held.arguments
      end

    if byte_size(arguments) > @maximum_arguments_bytes do
      {:error, :invalid_provider_event}
    else
      merged = %{
        id: text_or(call["id"], held.id),
        name: text_or(function["name"], held.name),
        arguments: arguments
      }

      {:ok, %{state | calls: Map.put(state.calls, index, merged)}}
    end
  end

  defp tool_call(_state, _invalid), do: {:error, :invalid_provider_event}

  defp text_or(value, _fallback) when is_binary(value) and value != "", do: value
  defp text_or(_value, fallback), do: fallback

  defp tool_call_events(%__MODULE__{calls: calls} = state) do
    calls
    |> Enum.sort_by(fn {index, _call} -> index end)
    |> Enum.flat_map(fn {index, call} -> tool_call_event(state, index, call) end)
  end

  defp tool_call_event(state, index, %{name: name} = call) when is_binary(name) do
    if Regex.match?(@tool_name_regex, name) and byte_size(name) <= 128 do
      call_id = call.id || "#{id(state)}-#{index}"

      [
        {:tool_call,
         %ToolCall{
           item_id: call_id,
           call_id: call_id,
           name: name,
           raw_arguments: if(call.arguments == "", do: "{}", else: call.arguments)
         }}
      ]
    else
      []
    end
  end

  defp tool_call_event(_state, _index, _call), do: []

  defp start_response(%__MODULE__{response_id: nil} = state, response_id) do
    if valid_identifier?(response_id) do
      {:ok, %{state | response_id: response_id}, [{:response_started, response_id}]}
    else
      {:ok, %{state | response_id: nil}, []}
    end
  end

  defp start_response(%__MODULE__{} = state, _response_id), do: {:ok, state, []}

  defp usage(nil), do: {:ok, []}

  defp usage(usage) when is_map(usage) do
    input = integer(usage["prompt_tokens"])
    output = integer(usage["completion_tokens"])
    total = integer(usage["total_tokens"])

    if is_nil(input) and is_nil(output) and is_nil(total) do
      {:ok, []}
    else
      normalized =
        %{
          "input_tokens" => input || 0,
          "output_tokens" => output || 0,
          "total_tokens" => total || (input || 0) + (output || 0)
        }

      {:ok, [{:usage, normalized}]}
    end
  end

  defp usage(_usage), do: {:error, :invalid_provider_event}

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: nil

  defp id(%__MODULE__{response_id: nil}), do: "openrouter-response"
  defp id(%__MODULE__{response_id: response_id}), do: response_id

  defp valid_identifier?(value) when is_binary(value) and byte_size(value) in 1..256,
    do: Regex.match?(@identifier_regex, value)

  defp valid_identifier?(_value), do: false

  defp error_code(error) do
    code = error["code"] || error["type"]

    cond do
      is_binary(code) and byte_size(code) <= 128 and Regex.match?(@tool_name_regex, code) -> code
      is_integer(code) -> Integer.to_string(code)
      true -> nil
    end
  end
end
