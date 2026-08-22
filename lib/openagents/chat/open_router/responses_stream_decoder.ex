defmodule OpenAgents.Chat.OpenRouter.ResponsesStreamDecoder do
  @moduledoc false

  @maximum_buffer_bytes 262_144
  @maximum_delta_bytes 65_536
  @maximum_arguments_bytes 65_536
  @maximum_error_characters 240

  defstruct buffer: "",
            complete?: false,
            completion: nil,
            model: nil,
            assistant_message_id: nil,
            assistant_content: "",
            reasoning_summary: nil,
            reasoning_items: [],
            output_items: [],
            function_call_arguments: %{},
            text_event_family: nil,
            reasoning_event_family: nil

  @type completion :: map()

  def new(options \\ []) do
    %__MODULE__{model: Keyword.get(options, :model)}
  end

  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    buffer = String.replace(state.buffer <> chunk, "\r\n", "\n")

    if byte_size(buffer) > @maximum_buffer_bytes do
      {:error, :invalid_response}
    else
      parts = String.split(buffer, "\n\n")
      {frames, [remainder]} = Enum.split(parts, -1)
      decode_frames(%{state | buffer: remainder}, frames)
    end
  end

  def finish(%__MODULE__{complete?: true, completion: completion}) when is_map(completion),
    do: {:ok, completion}

  def finish(%__MODULE__{complete?: true} = state), do: streamed_completion(state)

  def finish(%__MODULE__{}), do: {:error, :invalid_response}

  defp decode_frames(state, frames) do
    Enum.reduce_while(frames, {:ok, state, []}, fn frame, {:ok, state, events} ->
      case decode_frame(state, frame) do
        {:ok, state, frame_events} -> {:cont, {:ok, state, events ++ frame_events}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_frame(state, frame) do
    data =
      frame
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", &(String.replace_prefix(&1, "data:", "") |> String.trim_leading()))

    case data do
      "" -> {:ok, state, []}
      "[DONE]" -> {:ok, %{state | complete?: true}, []}
      json -> decode_event(state, Jason.decode(json))
    end
  end

  defp decode_event(_state, {:error, _reason}), do: {:error, :invalid_response}

  defp decode_event(_state, {:ok, %{"type" => "error"} = event}),
    do: {:error, provider_event_error(event)}

  defp decode_event(state, {:ok, %{"type" => "response.content_part.delta", "delta" => delta}})
       when is_binary(delta) and byte_size(delta) <= @maximum_delta_bytes,
       do: append_text_delta(state, delta, :content_part)

  defp decode_event(state, {:ok, %{"type" => "response.output_text.delta", "delta" => delta}})
       when is_binary(delta) and byte_size(delta) <= @maximum_delta_bytes,
       do: append_text_delta(state, delta, :output_text)

  defp decode_event(state, {:ok, %{"type" => "response.reasoning.delta", "delta" => delta}})
       when is_binary(delta) and byte_size(delta) <= @maximum_delta_bytes,
       do: append_reasoning_delta(state, delta, :reasoning)

  defp decode_event(
         state,
         {:ok, %{"type" => "response.reasoning_text.delta", "delta" => delta}}
       )
       when is_binary(delta) and byte_size(delta) <= @maximum_delta_bytes,
       do: append_reasoning_delta(state, delta, :reasoning_text)

  defp decode_event(
         state,
         {:ok, %{"type" => "response.reasoning_summary_text.delta", "delta" => delta}}
       )
       when is_binary(delta) and byte_size(delta) <= @maximum_delta_bytes,
       do: append_reasoning_delta(state, delta, :reasoning_summary_text)

  defp decode_event(
         state,
         {:ok, %{"type" => "response.reasoning_summary.delta", "delta" => delta}}
       )
       when is_binary(delta) and byte_size(delta) <= @maximum_delta_bytes,
       do: append_reasoning_delta(state, delta, :reasoning_summary)

  defp decode_event(
         state,
         {:ok, %{"type" => "response.output_item.added", "item" => item} = event}
       )
       when is_map(item),
       do: {:ok, capture_output_item(state, item, event["output_index"]), []}

  defp decode_event(
         state,
         {:ok, %{"type" => "response.output_item.done", "item" => item} = event}
       )
       when is_map(item),
       do: {:ok, capture_output_item(state, item, event["output_index"]), []}

  defp decode_event(
         state,
         {:ok,
          %{
            "type" => "response.function_call_arguments.delta",
            "item_id" => item_id,
            "delta" => delta
          }}
       )
       when is_binary(item_id) and is_binary(delta) do
    append_function_call_arguments(state, item_id, delta)
  end

  defp decode_event(
         state,
         {:ok,
          %{
            "type" => "response.function_call_arguments.done",
            "item_id" => item_id,
            "arguments" => arguments
          }}
       )
       when is_binary(item_id) and is_binary(arguments) and
              byte_size(arguments) <= @maximum_arguments_bytes do
    {:ok, put_function_call_arguments(state, item_id, arguments), []}
  end

  defp decode_event(state, {:ok, %{"type" => type, "response" => response}})
       when type in ["response.completed", "response.done"] and is_map(response) do
    complete_response(state, response)
  end

  defp decode_event(_state, {:ok, %{"type" => type} = event})
       when type in ["response.failed", "response.incomplete"],
       do: {:error, provider_event_error(event)}

  defp decode_event(state, {:ok, %{"type" => _type}}), do: {:ok, state, []}
  defp decode_event(_state, {:ok, _event}), do: {:error, :invalid_response}

  defp complete_response(state, response)
       when is_map(response) do
    state = capture_model(state, response["model"])
    output = terminal_output(response["output"], state)

    response =
      response
      |> Map.put_new("object", "response")
      |> maybe_put_model(state.model)
      |> maybe_put_output(output)

    case completion(response) do
      {:ok, completion} ->
        completion = merge_streamed_reasoning(completion, state)
        {:ok, %{state | complete?: true, completion: completion}, []}

      {:error, :invalid_response} ->
        {:ok, %{state | complete?: true}, []}
    end
  end

  defp merge_streamed_reasoning(completion, state) do
    completion =
      if is_binary(state.reasoning_summary) do
        Map.put_new(completion, "reasoning_summary", state.reasoning_summary)
      else
        completion
      end

    if state.reasoning_items == [] do
      completion
    else
      Map.put_new(completion, "reasoning_items", state.reasoning_items)
    end
  end

  defp append_text_delta(%{text_event_family: nil} = state, delta, family) do
    {:ok,
     %{
       state
       | assistant_content: state.assistant_content <> delta,
         text_event_family: family
     }, [{:text_delta, delta}]}
  end

  defp append_text_delta(%{text_event_family: family} = state, delta, family) do
    {:ok, %{state | assistant_content: state.assistant_content <> delta}, [{:text_delta, delta}]}
  end

  defp append_text_delta(state, _delta, _other_family), do: {:ok, state, []}

  defp append_reasoning_delta(%{reasoning_event_family: nil} = state, delta, family) do
    {:ok,
     %{
       state
       | reasoning_summary: (state.reasoning_summary || "") <> delta,
         reasoning_event_family: family
     }, [{:reasoning_delta, delta}]}
  end

  defp append_reasoning_delta(%{reasoning_event_family: family} = state, delta, family) do
    {:ok, %{state | reasoning_summary: (state.reasoning_summary || "") <> delta},
     [{:reasoning_delta, delta}]}
  end

  defp append_reasoning_delta(state, _delta, _other_family), do: {:ok, state, []}

  defp completion(%{"object" => "response", "model" => model, "output" => output})
       when is_binary(model) and is_list(output) do
    case tool_calls(output) do
      [] ->
        assistant_completion(model, output)

      tool_calls ->
        %{
          "object" => "response",
          "model" => model,
          "output" => output,
          "tool_calls" => tool_calls
        }
        |> maybe_put_reasoning_summary(output)
        |> maybe_put_reasoning_items(output)
        |> then(&{:ok, &1})
    end
  end

  defp completion(_response), do: {:error, :invalid_response}

  defp assistant_message?(%{"type" => "message", "role" => "assistant", "status" => "completed"}),
    do: true

  defp assistant_message?(_item), do: false

  defp assistant_completion(model, output) do
    with %{"id" => id, "role" => "assistant", "status" => "completed", "content" => content} <-
           Enum.find(output, &assistant_message?/1),
         true <- is_binary(id) and byte_size(id) in 1..256,
         %{"type" => "output_text", "text" => text} <- Enum.find(content, &output_text?/1),
         true <- is_binary(text) do
      completion = %{
        "object" => "response",
        "model" => model,
        "output" => output,
        "assistant_message_id" => id,
        "assistant_content" => text
      }

      completion
      |> maybe_put_reasoning_summary(output)
      |> maybe_put_reasoning_items(output)
      |> then(&{:ok, &1})
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  defp tool_calls(output) do
    output
    |> Enum.filter(&function_call?/1)
    |> Enum.map(&normalize_tool_call/1)
    |> Enum.reject(&is_nil/1)
  end

  defp function_call?(%{"type" => "function_call"}), do: true
  defp function_call?(_item), do: false

  defp normalize_tool_call(%{
         "id" => id,
         "call_id" => call_id,
         "name" => name,
         "arguments" => arguments
       })
       when is_binary(id) and is_binary(call_id) and is_binary(name) and is_binary(arguments) do
    %{
      "type" => "function_call",
      "id" => id,
      "call_id" => call_id,
      "name" => name,
      "arguments" => arguments
    }
  end

  defp normalize_tool_call(_item), do: nil

  defp maybe_put_reasoning_summary(completion, output) do
    summary =
      output
      |> Enum.filter(&reasoning?/1)
      |> Enum.flat_map(&Map.get(&1, "summary", []))
      |> Enum.map(&reasoning_summary_text/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    if summary == "", do: completion, else: Map.put(completion, "reasoning_summary", summary)
  end

  defp maybe_put_reasoning_items(completion, output) do
    items = Enum.filter(output, &reasoning_item?/1)
    if items == [], do: completion, else: Map.put(completion, "reasoning_items", items)
  end

  defp reasoning?(%{"type" => "reasoning", "summary" => summary}) when is_list(summary), do: true
  defp reasoning?(_item), do: false

  defp reasoning_summary_text(text) when is_binary(text) and byte_size(text) > 0, do: text

  defp reasoning_summary_text(%{"type" => "summary_text", "text" => text})
       when is_binary(text) and byte_size(text) > 0,
       do: text

  defp reasoning_summary_text(_summary), do: nil

  defp reasoning_item?(%{"type" => "reasoning", "id" => id, "encrypted_content" => content})
       when is_binary(id) and is_binary(content),
       do: true

  defp reasoning_item?(_item), do: false

  defp capture_model(state, model) when is_binary(model), do: %{state | model: model}
  defp capture_model(state, _model), do: state

  defp capture_output_item(state, item, output_index) do
    item = maybe_put_function_call_arguments(item, state.function_call_arguments)

    state = %{
      state
      | output_items: upsert_output_item(state.output_items, item, output_index)
    }

    capture_output_item_details(state, item)
  end

  defp capture_output_item_details(
         state,
         %{
           "type" => "message",
           "id" => id,
           "role" => "assistant"
         } = item
       )
       when is_binary(id) do
    content = output_text(item["content"])

    %{
      state
      | assistant_message_id: id,
        assistant_content: content || state.assistant_content
    }
  end

  defp capture_output_item_details(state, %{"type" => "reasoning"} = item) do
    state = capture_reasoning_item(state, item)
    summary = Map.get(item, "summary", [])

    capture_reasoning_summary(state, summary)
  end

  defp capture_output_item_details(state, _item), do: state

  defp upsert_output_item(output_items, item, output_index) do
    key = output_item_key(item, output_index)

    case Enum.find_index(output_items, fn {existing_key, _item} -> existing_key == key end) do
      nil -> output_items ++ [{key, item}]
      index -> List.replace_at(output_items, index, {key, item})
    end
  end

  defp output_item_key(_item, output_index)
       when is_integer(output_index) and output_index >= 0,
       do: {:index, output_index}

  defp output_item_key(%{"id" => id}, _output_index) when is_binary(id), do: {:id, id}
  defp output_item_key(_item, _output_index), do: make_ref()

  defp append_function_call_arguments(state, item_id, delta)
       when byte_size(delta) <= @maximum_arguments_bytes do
    arguments = Map.get(state.function_call_arguments, item_id, "") <> delta

    if byte_size(arguments) <= @maximum_arguments_bytes do
      {:ok, put_function_call_arguments(state, item_id, arguments), []}
    else
      {:error, :invalid_response}
    end
  end

  defp append_function_call_arguments(_state, _item_id, _delta),
    do: {:error, :invalid_response}

  defp put_function_call_arguments(state, item_id, arguments) do
    argument_map = Map.put(state.function_call_arguments, item_id, arguments)

    output_items =
      Enum.map(state.output_items, fn {key, item} ->
        {key, maybe_put_function_call_arguments(item, argument_map)}
      end)

    %{state | function_call_arguments: argument_map, output_items: output_items}
  end

  defp maybe_put_function_call_arguments(
         %{"type" => "function_call", "id" => item_id} = item,
         argument_map
       )
       when is_binary(item_id) do
    case Map.get(argument_map, item_id) do
      arguments when is_binary(arguments) -> Map.put(item, "arguments", arguments)
      _missing -> item
    end
  end

  defp maybe_put_function_call_arguments(item, _argument_map), do: item

  defp capture_reasoning_item(
         state,
         %{"id" => id, "encrypted_content" => content} = item
       )
       when is_binary(id) and is_binary(content) do
    %{state | reasoning_items: state.reasoning_items ++ [item]}
  end

  defp capture_reasoning_item(state, _item), do: state

  defp capture_reasoning_summary(state, summary) when is_list(summary) do
    summary =
      summary
      |> Enum.map(&reasoning_summary_text/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    if summary == "", do: state, else: %{state | reasoning_summary: summary}
  end

  defp capture_reasoning_summary(state, _summary), do: state

  defp terminal_output(output, state) when is_list(output) and output != [] do
    Enum.map(output, &maybe_put_function_call_arguments(&1, state.function_call_arguments))
  end

  defp terminal_output(_output, state) do
    Enum.map(state.output_items, fn {_key, item} -> item end)
  end

  defp maybe_put_model(response, model) when is_binary(model),
    do: Map.put_new(response, "model", model)

  defp maybe_put_model(response, _model), do: response

  defp maybe_put_output(response, output) when is_list(output) and output != [],
    do: Map.put(response, "output", output)

  defp maybe_put_output(response, _output), do: response

  defp provider_event_error(event) do
    response = map_or_empty(event["response"])
    error = map_or_empty(event["error"] || response["error"])
    incomplete_details = map_or_empty(response["incomplete_details"])

    code =
      event["error_type"] ||
        error["code"] ||
        incomplete_details["reason"] ||
        "provider_error"

    message = error["message"] || incomplete_details["message"]

    {:provider_error, normalize_error_code(code), normalize_error_message(message)}
  end

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

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
    |> String.slice(0, @maximum_error_characters)
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_error_message(_message), do: nil

  defp streamed_completion(
         %{
           model: model,
           assistant_message_id: id,
           assistant_content: content
         } = state
       )
       when is_binary(model) and is_binary(id) and is_binary(content) and content != "" do
    completion = %{
      "object" => "response",
      "model" => model,
      "assistant_message_id" => id,
      "assistant_content" => content
    }

    completion =
      if is_binary(state.reasoning_summary) do
        Map.put(completion, "reasoning_summary", state.reasoning_summary)
      else
        completion
      end

    if state.reasoning_items == [] do
      {:ok, completion}
    else
      {:ok, Map.put(completion, "reasoning_items", state.reasoning_items)}
    end
  end

  defp streamed_completion(_state), do: {:error, :invalid_response}

  defp output_text(content) when is_list(content) do
    case Enum.find(content, &output_text?/1) do
      %{"text" => text} -> text
      _missing -> nil
    end
  end

  defp output_text(_content), do: nil

  defp output_text?(%{"type" => "output_text", "text" => text}) when is_binary(text), do: true
  defp output_text?(_part), do: false
end
