defmodule OpenAgents.Providers.OpenAI.StreamDecoder do
  @moduledoc false

  alias OpenAgents.Providers.ProviderEvent.ToolCall

  @maximum_buffer_bytes 262_144
  @maximum_delta_bytes 65_536
  @maximum_arguments_bytes 65_536
  @identifier_regex ~r/\A[a-zA-Z0-9_.:-]+\z/
  @tool_name_regex ~r/\A[a-zA-Z0-9_-]+\z/

  defstruct buffer: "", response_id: nil, terminal?: false

  @type t :: %__MODULE__{
          buffer: String.t(),
          response_id: String.t() | nil,
          terminal?: boolean()
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

  @spec finish(t()) :: {:ok, t(), [OpenAgents.Providers.ProviderEvent.t()]} | {:error, atom()}
  def finish(%__MODULE__{buffer: buffer} = state) do
    with {:ok, state, events} <- decode_final_buffer(state, buffer) do
      if state.terminal?, do: {:ok, state, events}, else: {:error, :truncated_stream}
    end
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
      "[DONE]" -> {:ok, state, []}
      json -> decode_json(state, Jason.decode(json))
    end
  end

  defp decode_json(_state, {:error, _error}), do: {:error, :invalid_provider_event}

  defp decode_json(state, {:ok, %{"type" => type, "response" => response}})
       when type in ["response.created", "response.in_progress"] and is_map(response) do
    start_response(state, response["id"])
  end

  defp decode_json(state, {:ok, %{"type" => "response.output_text.delta", "delta" => delta}})
       when is_binary(delta) and byte_size(delta) <= @maximum_delta_bytes do
    {:ok, state, [{:text_delta, delta}]}
  end

  # The Responses API streams reasoning as its own event families: the
  # summary text most models expose, and the raw reasoning text some do.
  # Both become the one neutral reasoning event.
  defp decode_json(state, {:ok, %{"type" => type, "delta" => delta}})
       when type in ["response.reasoning_summary_text.delta", "response.reasoning_text.delta"] and
              is_binary(delta) and byte_size(delta) <= @maximum_delta_bytes do
    {:ok, state, [{:reasoning_delta, delta}]}
  end

  defp decode_json(
         state,
         {:ok,
          %{
            "type" => "response.output_item.done",
            "item" => %{"type" => "function_call"} = item
          }}
       ) do
    with :ok <- validate_identifier(item["id"]),
         :ok <- validate_identifier(item["call_id"]),
         :ok <- validate_tool_name(item["name"]),
         :ok <- validate_arguments(item["arguments"]) do
      tool_call = %ToolCall{
        item_id: item["id"],
        call_id: item["call_id"],
        name: item["name"],
        raw_arguments: item["arguments"]
      }

      {:ok, state, [{:tool_call, tool_call}]}
    end
  end

  defp decode_json(state, {:ok, %{"type" => "response.completed", "response" => response}})
       when is_map(response) do
    with {:ok, started_state, start_events} <- start_response(state, response["id"]),
         {:ok, usage} <- normalize_usage(response["usage"]) do
      events =
        start_events ++ usage_events(usage) ++ [{:response_completed, response["id"]}]

      {:ok, %{started_state | terminal?: true}, events}
    end
  end

  defp decode_json(
         state,
         {:ok, %{"type" => "response.cancelled", "response" => response}}
       )
       when is_map(response) do
    with {:ok, started_state, start_events} <- start_response(state, response["id"]) do
      {:ok, %{started_state | terminal?: true}, start_events ++ [:cancelled]}
    end
  end

  defp decode_json(state, {:ok, %{"type" => "response.cancelled"}}),
    do: {:ok, %{state | terminal?: true}, [:cancelled]}

  defp decode_json(
         state,
         {:ok, %{"type" => type, "response" => response} = event}
       )
       when type in ["response.failed", "response.incomplete"] and is_map(response) do
    with {:ok, started_state, start_events} <- start_response(state, response["id"]) do
      code = normalized_error_code(event)

      {:ok, %{started_state | terminal?: true},
       start_events ++ [{:failed, {:provider_failed, code}}]}
    end
  end

  defp decode_json(state, {:ok, %{"type" => type} = event})
       when type in ["error", "response.failed", "response.incomplete"] do
    code = normalized_error_code(event)
    {:ok, %{state | terminal?: true}, [{:failed, {:provider_failed, code}}]}
  end

  defp decode_json(state, {:ok, %{"type" => _unknown_type}}), do: {:ok, state, []}
  defp decode_json(_state, {:ok, _invalid}), do: {:error, :invalid_provider_event}

  defp start_response(%__MODULE__{response_id: nil} = state, response_id) do
    with :ok <- validate_identifier(response_id) do
      {:ok, %{state | response_id: response_id}, [{:response_started, response_id}]}
    end
  end

  defp start_response(%__MODULE__{response_id: response_id} = state, response_id),
    do: {:ok, state, []}

  defp start_response(_state, _response_id), do: {:error, :invalid_provider_event}

  defp validate_identifier(value)
       when is_binary(value) and byte_size(value) in 1..256 do
    if Regex.match?(@identifier_regex, value), do: :ok, else: {:error, :invalid_provider_event}
  end

  defp validate_identifier(_value), do: {:error, :invalid_provider_event}

  defp validate_tool_name(value) when is_binary(value) and byte_size(value) in 1..128 do
    if Regex.match?(@tool_name_regex, value), do: :ok, else: {:error, :invalid_provider_event}
  end

  defp validate_tool_name(_value), do: {:error, :invalid_provider_event}

  defp validate_arguments(value)
       when is_binary(value) and byte_size(value) <= @maximum_arguments_bytes,
       do: :ok

  defp validate_arguments(_value), do: {:error, :invalid_provider_event}

  defp normalize_usage(nil), do: {:ok, nil}

  defp normalize_usage(usage) when is_map(usage) and map_size(usage) <= 32 do
    normalized =
      %{
        "input_tokens" => first_value([usage["input_tokens"], usage["prompt_tokens"]]),
        "output_tokens" => first_value([usage["output_tokens"], usage["completion_tokens"]]),
        "total_tokens" => first_value([usage["total_tokens"]]),
        "cache_read_input_tokens" =>
          first_value([
            get_in(usage, ["input_tokens_details", "cached_tokens"]),
            get_in(usage, ["prompt_tokens_details", "cached_tokens"])
          ]),
        "reasoning_output_tokens" =>
          first_value([
            get_in(usage, ["output_tokens_details", "reasoning_tokens"]),
            get_in(usage, ["completion_tokens_details", "reasoning_tokens"])
          ])
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if Enum.all?(normalized, fn {_key, value} -> is_integer(value) and value >= 0 end),
      do: {:ok, normalized},
      else: {:error, :invalid_provider_event}
  end

  defp normalize_usage(_usage), do: {:error, :invalid_provider_event}

  defp first_value(values), do: Enum.find(values, fn value -> not is_nil(value) end)

  defp usage_events(nil), do: []
  defp usage_events(usage), do: [{:usage, usage}]

  defp normalized_error_code(event) do
    code = get_in(event, ["error", "code"]) || get_in(event, ["response", "error", "code"])

    if is_binary(code) and byte_size(code) <= 128 and Regex.match?(@tool_name_regex, code),
      do: code,
      else: nil
  end
end
