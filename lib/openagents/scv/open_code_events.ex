defmodule OpenAgents.SCV.OpenCodeEvents do
  @moduledoc """
  Aggregates content-free usage data from OpenCode JSON event lines.

  The raw event artifact remains the source for operator diagnosis. This module
  retains only bounded event names, identifiers, counters, token totals, costs,
  and tool outcomes in the run summary.
  """

  @maximum_event_type_bytes 64
  @maximum_session_id_bytes 128
  @maximum_tool_name_bytes 128
  @maximum_status_bytes 32

  @type t :: %{
          event_count: non_neg_integer(),
          diagnostic_line_count: non_neg_integer(),
          invalid_event_count: non_neg_integer(),
          event_types: %{optional(String.t()) => pos_integer()},
          session_ids: MapSet.t(String.t()),
          text_event_count: non_neg_integer(),
          error_event_count: non_neg_integer(),
          tool_calls: %{optional(String.t()) => pos_integer()},
          tool_outcomes: %{optional(String.t()) => pos_integer()},
          usage: %{
            input_tokens: number(),
            output_tokens: number(),
            reasoning_tokens: number(),
            cache_read_tokens: number(),
            cache_write_tokens: number(),
            cost_usd: number()
          }
        }

  @spec new() :: t()
  def new do
    %{
      event_count: 0,
      diagnostic_line_count: 0,
      invalid_event_count: 0,
      event_types: %{},
      session_ids: MapSet.new(),
      text_event_count: 0,
      error_event_count: 0,
      tool_calls: %{},
      tool_outcomes: %{},
      usage: %{
        input_tokens: 0,
        output_tokens: 0,
        reasoning_tokens: 0,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        cost_usd: 0
      }
    }
  end

  @spec ingest(t(), binary()) :: t()
  def ingest(state, line) when is_map(state) and is_binary(line) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) ->
        ingest_event(state, event)

      _invalid ->
        if diagnostic_line?(line) do
          Map.update!(state, :diagnostic_line_count, &(&1 + 1))
        else
          Map.update!(state, :invalid_event_count, &(&1 + 1))
        end
    end
  end

  @spec summary(t()) :: map()
  def summary(state) when is_map(state) do
    %{
      event_count: state.event_count,
      diagnostic_line_count: state.diagnostic_line_count,
      invalid_event_count: state.invalid_event_count,
      event_types: state.event_types,
      session_ids: state.session_ids |> MapSet.to_list() |> Enum.sort(),
      text_event_count: state.text_event_count,
      error_event_count: state.error_event_count,
      tool_calls: state.tool_calls,
      tool_outcomes: state.tool_outcomes,
      usage: state.usage
    }
  end

  defp ingest_event(state, event) do
    type = bounded_identifier(event["type"], @maximum_event_type_bytes, "unknown")
    session_id = bounded_identifier(event["sessionID"], @maximum_session_id_bytes, nil)

    state
    |> Map.update!(:event_count, &(&1 + 1))
    |> update_counter(:event_types, type)
    |> maybe_add_session(session_id)
    |> maybe_count_text(type)
    |> maybe_count_error(type)
    |> maybe_count_tool(type, event["part"])
    |> maybe_add_usage(type, event["part"])
  end

  defp maybe_add_session(state, nil), do: state

  defp maybe_add_session(state, session_id) do
    Map.update!(state, :session_ids, &MapSet.put(&1, session_id))
  end

  defp maybe_count_text(state, "text"), do: Map.update!(state, :text_event_count, &(&1 + 1))
  defp maybe_count_text(state, _type), do: state

  defp maybe_count_error(state, "error"), do: Map.update!(state, :error_event_count, &(&1 + 1))
  defp maybe_count_error(state, _type), do: state

  defp maybe_count_tool(state, "tool_use", part) when is_map(part) do
    tool = bounded_identifier(part["tool"], @maximum_tool_name_bytes, "unknown")

    status =
      bounded_identifier(get_in(part, ["state", "status"]), @maximum_status_bytes, "unknown")

    state
    |> update_counter(:tool_calls, tool)
    |> update_counter(:tool_outcomes, tool <> ":" <> status)
  end

  defp maybe_count_tool(state, _type, _part), do: state

  defp maybe_add_usage(state, "step_finish", part) when is_map(part) do
    tokens = if is_map(part["tokens"]), do: part["tokens"], else: %{}
    cache = if is_map(tokens["cache"]), do: tokens["cache"], else: %{}

    additions = %{
      input_tokens: non_negative_number(tokens["input"]),
      output_tokens: non_negative_number(tokens["output"]),
      reasoning_tokens: non_negative_number(tokens["reasoning"]),
      cache_read_tokens: non_negative_number(cache["read"]),
      cache_write_tokens: non_negative_number(cache["write"]),
      cost_usd: non_negative_number(part["cost"])
    }

    Map.update!(state, :usage, fn usage ->
      Map.new(usage, fn {key, value} -> {key, value + Map.fetch!(additions, key)} end)
    end)
  end

  defp maybe_add_usage(state, _type, _part), do: state

  defp update_counter(state, key, value) do
    Map.update!(state, key, &Map.update(&1, value, 1, fn count -> count + 1 end))
  end

  defp bounded_identifier(value, maximum_bytes, _fallback)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum_bytes,
       do: value

  defp bounded_identifier(_value, _maximum_bytes, fallback), do: fallback

  defp non_negative_number(value) when is_number(value) and value >= 0, do: value
  defp non_negative_number(_value), do: 0

  defp diagnostic_line?(line) do
    String.starts_with?(line, "timestamp=") and String.contains?(line, " level=")
  end
end
