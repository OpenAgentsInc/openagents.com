defmodule OpenAgents.Voice.Usage do
  @moduledoc "Whitelisted Realtime token accounting and versioned conservative cost estimates."

  @pricing_id "openai.gpt-realtime-2.1.2026-08-16"
  @numeric_fields ~w(input_tokens output_tokens total_tokens input_text_tokens input_audio_tokens input_image_tokens input_cached_tokens input_cached_text_tokens input_cached_audio_tokens input_cached_image_tokens input_unclassified_tokens output_text_tokens output_audio_tokens output_reasoning_tokens output_unclassified_tokens estimated_cost_microusd)

  @spec normalize_provider(map() | nil) :: map() | nil
  def normalize_provider(usage) when is_map(usage) do
    if Enum.any?(~w(input_tokens output_tokens total_tokens), &valid_integer?(usage[&1])) do
      input = map(usage["input_token_details"])
      cached = map(input["cached_tokens_details"])
      output = map(usage["output_token_details"])

      %{
        "input_tokens" => integer(usage["input_tokens"]),
        "output_tokens" => integer(usage["output_tokens"]),
        "total_tokens" => integer(usage["total_tokens"]),
        "input_text_tokens" => integer(input["text_tokens"]),
        "input_audio_tokens" => integer(input["audio_tokens"]),
        "input_image_tokens" => integer(input["image_tokens"]),
        "input_cached_tokens" => integer(input["cached_tokens"]),
        "input_cached_text_tokens" => integer(cached["text_tokens"]),
        "input_cached_audio_tokens" => integer(cached["audio_tokens"]),
        "input_cached_image_tokens" => integer(cached["image_tokens"]),
        "output_text_tokens" => integer(output["text_tokens"]),
        "output_audio_tokens" => integer(output["audio_tokens"]),
        "output_reasoning_tokens" => integer(output["reasoning_tokens"])
      }
    else
      nil
    end
  end

  def normalize_provider(_usage), do: nil

  @spec price(map(), String.t()) :: map()
  def price(usage, "gpt-realtime-2.1") when is_map(usage) do
    usage = Map.merge(Map.new(@numeric_fields, &{&1, 0}), usage)

    input_classified =
      integer(usage["input_text_tokens"]) + integer(usage["input_audio_tokens"]) +
        integer(usage["input_image_tokens"])

    output_classified =
      integer(usage["output_text_tokens"]) + integer(usage["output_audio_tokens"])

    input_unclassified = max(integer(usage["input_tokens"]) - input_classified, 0)
    output_unclassified = max(integer(usage["output_tokens"]) - output_classified, 0)

    cost =
      noncached(usage, "input_text_tokens", "input_cached_text_tokens") * 4 +
        noncached(usage, "input_audio_tokens", "input_cached_audio_tokens") * 32 +
        noncached(usage, "input_image_tokens", "input_cached_image_tokens") * 5 +
        integer(usage["input_cached_text_tokens"]) * 0.4 +
        integer(usage["input_cached_audio_tokens"]) * 0.4 +
        integer(usage["input_cached_image_tokens"]) * 0.5 +
        integer(usage["output_text_tokens"]) * 24 +
        integer(usage["output_audio_tokens"]) * 64 +
        input_unclassified * 32 +
        output_unclassified * 64

    usage
    |> Map.put("schema", "sarah.voice_usage.v1")
    |> Map.put("pricing_id", @pricing_id)
    |> Map.put("input_unclassified_tokens", input_unclassified)
    |> Map.put("output_unclassified_tokens", output_unclassified)
    |> Map.put("estimated_cost_microusd", ceil(cost))
  end

  def price(usage, _unpriced_model) when is_map(usage) do
    usage = Map.merge(Map.new(@numeric_fields, &{&1, 0}), usage)

    usage
    |> Map.put("schema", "sarah.voice_usage.v1")
    |> Map.put("pricing_id", "unpriced")
    |> Map.put("input_unclassified_tokens", usage["input_tokens"] || 0)
    |> Map.put("output_unclassified_tokens", usage["output_tokens"] || 0)
    |> Map.put("estimated_cost_microusd", 0)
  end

  @spec merge(map(), map()) :: map()
  def merge(existing, reported) when is_map(existing) and is_map(reported) do
    totals =
      Map.new(@numeric_fields, fn key ->
        {key, integer(existing[key]) + integer(reported[key])}
      end)

    totals
    |> Map.put("schema", "sarah.voice_usage.v1")
    |> Map.put("pricing_id", reported["pricing_id"] || existing["pricing_id"] || "unpriced")
  end

  @spec over_budget?(map()) :: boolean()
  def over_budget?(usage) when is_map(usage) do
    integer(usage["total_tokens"]) >=
      Application.fetch_env!(:openagents, :voice_maximum_session_tokens) or
      integer(usage["estimated_cost_microusd"]) >=
        Application.fetch_env!(:openagents, :voice_maximum_estimated_cost_microusd)
  end

  @doc """
  True once the session has consumed 80% of either budget ceiling, so the
  runtime can warn the model to wrap up before `over_budget?/1` ends the call.
  """
  @spec near_budget?(map()) :: boolean()
  def near_budget?(usage) when is_map(usage) do
    token_budget = Application.fetch_env!(:openagents, :voice_maximum_session_tokens)
    cost_budget = Application.fetch_env!(:openagents, :voice_maximum_estimated_cost_microusd)

    integer(usage["total_tokens"]) * 10 >= token_budget * 8 or
      integer(usage["estimated_cost_microusd"]) * 10 >= cost_budget * 8
  end

  defp noncached(usage, total_key, cached_key),
    do: max(integer(usage[total_key]) - integer(usage[cached_key]), 0)

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0
  defp valid_integer?(value), do: is_integer(value) and value >= 0
end
