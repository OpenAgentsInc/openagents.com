defmodule OpenAgents.Analytics.Chat do
  @moduledoc """
  The chat lifecycle event vocabulary.

  Chat instrumentation spans a LiveView, a turn server, and the OpenRouter
  provider path, so the event names, the property names, and the token
  normalization live here instead of being spelled out at each call site. Every
  function returns `:ok` through `OpenAgents.Analytics.capture/3`, which drops
  sensitive keys and never fails its caller.

  Token counts are provider-reported totals for a whole turn. `tokens_used/3`
  is the only place a turn reports them, so a turn that ran several provider
  rounds or fell back to another API still produces one event.
  """

  alias OpenAgents.Analytics

  @stream_chunk_interval_ms 1_000

  @doc "A user message that waited behind an active turn."
  @spec message_queued(Analytics.distinct_id(), map()) :: :ok
  def message_queued(distinct_id, properties \\ %{}),
    do: Analytics.capture("chat_message_queued", distinct_id, properties)

  @doc "An assistant message that reached the user."
  @spec message_received(Analytics.distinct_id(), map()) :: :ok
  def message_received(distinct_id, properties \\ %{}),
    do: Analytics.capture("chat_message_received", distinct_id, properties)

  @doc """
  The provider-reported token counts for one turn.

  Accepts either naming the two OpenRouter APIs use (`input_tokens` and
  `output_tokens`, or `prompt_tokens` and `completion_tokens`). A usage map
  without any readable count captures nothing, because a missing count is not
  a zero.
  """
  @spec tokens_used(Analytics.distinct_id(), map() | nil, map()) :: :ok
  def tokens_used(distinct_id, usage, properties \\ %{})

  def tokens_used(distinct_id, usage, properties) when is_map(usage) do
    case token_counts(usage) do
      nil -> :ok
      counts -> Analytics.capture("chat_tokens_used", distinct_id, Map.merge(properties, counts))
    end
  end

  def tokens_used(_distinct_id, _usage, _properties), do: :ok

  @doc "A turn that ended anywhere other than completed."
  @spec turn_failed(Analytics.distinct_id(), map()) :: :ok
  def turn_failed(distinct_id, properties \\ %{}),
    do: Analytics.capture("chat_turn_failed", distinct_id, properties)

  @doc """
  One assistant stream chunk, rate-limited to one event per second.

  Callers hold the throttle: pass the value the previous call returned and keep
  the returned value. `nil` means nothing has been captured for this turn yet.
  """
  @spec stream_chunk(Analytics.distinct_id(), integer() | nil, map()) :: integer() | nil
  def stream_chunk(distinct_id, last_captured_at, properties \\ %{}) do
    now = System.monotonic_time(:millisecond)

    if throttled?(last_captured_at, now) do
      last_captured_at
    else
      Analytics.capture("chat_stream_chunk", distinct_id, properties)
      now
    end
  end

  @doc "A tool the assistant invoked during a turn."
  @spec tool_called(Analytics.distinct_id(), map()) :: :ok
  def tool_called(distinct_id, properties \\ %{}),
    do: Analytics.capture("chat_tool_called", distinct_id, properties)

  @doc "A voice session that began accepting audio."
  @spec voice_started(Analytics.distinct_id(), map()) :: :ok
  def voice_started(distinct_id, properties \\ %{}),
    do: Analytics.capture("chat_voice_started", distinct_id, properties)

  @doc "A voice session that stopped, with its duration when both ends are known."
  @spec voice_ended(Analytics.distinct_id(), map()) :: :ok
  def voice_ended(distinct_id, properties \\ %{}),
    do: Analytics.capture("chat_voice_ended", distinct_id, properties)

  @doc """
  The coarse size bucket for one message.

  Message text never enters an event property, so the bucket is what a reader
  gets: it separates a one-line ask from a pasted document without recording
  either.
  """
  @spec length_bucket(String.t()) :: String.t()
  def length_bucket(content) when is_binary(content) do
    cond do
      byte_size(content) < 100 -> "under_100"
      byte_size(content) < 1_000 -> "under_1k"
      byte_size(content) < 8_000 -> "under_8k"
      true -> "over_8k"
    end
  end

  defp throttled?(nil, _now), do: false

  defp throttled?(last_captured_at, now) when is_integer(last_captured_at),
    do: now - last_captured_at < @stream_chunk_interval_ms

  defp throttled?(_last_captured_at, _now), do: false

  defp token_counts(usage) do
    counts =
      %{
        "input_tokens" => count(usage, ["input_tokens", "prompt_tokens"]),
        "output_tokens" => count(usage, ["output_tokens", "completion_tokens"]),
        "total_tokens" => count(usage, ["total_tokens"])
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if counts == %{}, do: nil, else: counts
  end

  defp count(usage, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(usage, key) do
        value when is_integer(value) and value >= 0 -> value
        _other -> nil
      end
    end)
  end
end
