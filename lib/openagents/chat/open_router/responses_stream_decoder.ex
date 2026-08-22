defmodule OpenAgents.Chat.OpenRouter.ResponsesStreamDecoder do
  @moduledoc false

  @maximum_buffer_bytes 262_144
  @maximum_delta_bytes 65_536

  defstruct buffer: "",
            complete?: false,
            completion: nil,
            model: nil,
            assistant_message_id: nil,
            assistant_content: "",
            reasoning_summary: nil,
            reasoning_items: []

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
  defp decode_event(_state, {:ok, %{"type" => "error"}}), do: {:error, :provider_unavailable}

  defp decode_event(state, {:ok, %{"type" => "response.content_part.delta", "delta" => delta}})
       when is_binary(delta) and byte_size(delta) <= @maximum_delta_bytes,
       do:
         {:ok, %{state | assistant_content: state.assistant_content <> delta},
          [{:text_delta, delta}]}

  defp decode_event(state, {:ok, %{"type" => "response.reasoning.delta", "delta" => delta}})
       when is_binary(delta) and byte_size(delta) <= @maximum_delta_bytes,
       do: {:ok, state, [{:reasoning_delta, delta}]}

  defp decode_event(
         state,
         {:ok, %{"type" => "response.reasoning_summary_text.delta", "delta" => delta}}
       )
       when is_binary(delta) and byte_size(delta) <= @maximum_delta_bytes,
       do: {:ok, state, [{:reasoning_delta, delta}]}

  defp decode_event(
         state,
         {:ok, %{"type" => "response.output_item.added", "item" => item}}
       )
       when is_map(item),
       do: {:ok, capture_output_item(state, item), []}

  defp decode_event(
         state,
         {:ok, %{"type" => "response.output_item.done", "item" => item}}
       )
       when is_map(item),
       do: {:ok, capture_output_item(state, item), []}

  defp decode_event(state, {:ok, %{"type" => "response.done", "response" => response}})
       when is_map(response) do
    state = capture_model(state, response["model"])

    case completion(response) do
      {:ok, completion} -> {:ok, %{state | completion: completion}, []}
      {:error, :invalid_response} -> {:ok, state, []}
    end
  end

  defp decode_event(_state, {:ok, %{"type" => type}})
       when type in ["response.failed", "response.incomplete"],
       do: {:error, :provider_unavailable}

  defp decode_event(state, {:ok, %{"type" => _type}}), do: {:ok, state, []}
  defp decode_event(_state, {:ok, _event}), do: {:error, :invalid_response}

  defp completion(%{"object" => "response", "model" => model, "output" => output})
       when is_binary(model) and is_list(output) do
    case tool_calls(output) do
      [] -> assistant_completion(model, output)
      tool_calls -> {:ok, %{"object" => "response", "model" => model, "tool_calls" => tool_calls}}
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
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) > 0))
      |> Enum.join("\n\n")

    if summary == "", do: completion, else: Map.put(completion, "reasoning_summary", summary)
  end

  defp maybe_put_reasoning_items(completion, output) do
    items = Enum.filter(output, &reasoning_item?/1)
    if items == [], do: completion, else: Map.put(completion, "reasoning_items", items)
  end

  defp reasoning?(%{"type" => "reasoning", "summary" => summary}) when is_list(summary), do: true
  defp reasoning?(_item), do: false

  defp reasoning_item?(%{"type" => "reasoning", "id" => id, "encrypted_content" => content})
       when is_binary(id) and is_binary(content),
       do: true

  defp reasoning_item?(_item), do: false

  defp capture_model(state, model) when is_binary(model), do: %{state | model: model}
  defp capture_model(state, _model), do: state

  defp capture_output_item(
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

  defp capture_output_item(state, %{"type" => "reasoning"} = item) do
    state = capture_reasoning_item(state, item)
    summary = Map.get(item, "summary", [])

    capture_reasoning_summary(state, summary)
  end

  defp capture_output_item(state, _item), do: state

  defp capture_reasoning_item(
         state,
         %{"id" => id, "encrypted_content" => content} = item
       )
       when is_binary(id) and is_binary(content) do
    %{state | reasoning_items: state.reasoning_items ++ [item]}
  end

  defp capture_reasoning_item(state, _item), do: state

  defp capture_reasoning_summary(state, summary) when is_list(summary) do
    summary = summary |> Enum.filter(&is_binary/1) |> Enum.join("\n\n")
    if summary == "", do: state, else: %{state | reasoning_summary: summary}
  end

  defp capture_reasoning_summary(state, _summary), do: state

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
