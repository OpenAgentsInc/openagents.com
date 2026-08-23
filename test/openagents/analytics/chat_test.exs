defmodule OpenAgents.Analytics.ChatTest do
  @moduledoc """
  The chat lifecycle vocabulary is the only place chat instrumentation names an
  event or normalizes a token count, so these assertions pin the two decisions
  that operator dashboards depend on: which counts survive normalization, and
  that a stream reports at most one chunk event per second.
  """

  use ExUnit.Case, async: false

  alias OpenAgents.Analytics.Chat, as: ChatAnalytics

  defmodule TestSink do
    def capture(event, distinct_id, properties) do
      send(:chat_analytics_test_process, {:captured, event, distinct_id, properties})
      :ok
    end
  end

  setup do
    Process.register(self(), :chat_analytics_test_process)

    original_token = Application.get_env(:openagents, :posthog_project_token)
    original_sink = Application.get_env(:openagents, :analytics_sink)

    Application.put_env(:openagents, :posthog_project_token, "phc_test_token")
    Application.put_env(:openagents, :analytics_sink, TestSink)

    on_exit(fn ->
      restore_env(:posthog_project_token, original_token)
      restore_env(:analytics_sink, original_sink)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)

  defp captured do
    assert_receive {:captured, event, distinct_id, properties}, 500
    %{event: event, distinct_id: distinct_id, properties: properties}
  end

  describe "tokens_used/3" do
    test "provider token counts reach PostHog with the turn's identity" do
      :ok =
        ChatAnalytics.tokens_used(
          "user_abc",
          %{"input_tokens" => 1_200, "output_tokens" => 300, "total_tokens" => 1_500},
          %{"model" => "anthropic/claude-sonnet-4.5", "provider" => "openrouter"}
        )

      captured = captured()

      assert captured.event == "chat_tokens_used"
      assert captured.distinct_id == "user_abc"
      assert captured.properties["input_tokens"] == 1_200
      assert captured.properties["output_tokens"] == 300
      assert captured.properties["total_tokens"] == 1_500
      assert captured.properties["model"] == "anthropic/claude-sonnet-4.5"
      assert captured.properties["provider"] == "openrouter"
    end

    test "the Chat Completions spelling of the same counts normalizes" do
      :ok =
        ChatAnalytics.tokens_used("user_abc", %{
          "prompt_tokens" => 40,
          "completion_tokens" => 9
        })

      properties = captured().properties

      assert properties["input_tokens"] == 40
      assert properties["output_tokens"] == 9
    end

    test "a turn the provider never counted reports nothing" do
      assert :ok == ChatAnalytics.tokens_used("user_abc", nil)
      assert :ok == ChatAnalytics.tokens_used("user_abc", %{})
      assert :ok == ChatAnalytics.tokens_used("user_abc", %{"input_tokens" => "many"})

      refute_receive {:captured, _event, _distinct_id, _properties}, 100
    end
  end

  describe "stream_chunk/3" do
    test "the first chunk reports and the next chunk within the window does not" do
      captured_at = ChatAnalytics.stream_chunk("user_abc", nil, %{"modality" => "text"})

      assert is_integer(captured_at)
      assert captured().event == "chat_stream_chunk"

      assert captured_at == ChatAnalytics.stream_chunk("user_abc", captured_at, %{})
      refute_receive {:captured, _event, _distinct_id, _properties}, 100
    end

    test "a chunk past the window reports again" do
      stale = System.monotonic_time(:millisecond) - 2_000

      captured_at = ChatAnalytics.stream_chunk("user_abc", stale, %{})

      assert captured_at > stale
      assert captured().event == "chat_stream_chunk"
    end
  end

  describe "the remaining lifecycle events" do
    test "each helper names its own event" do
      :ok = ChatAnalytics.message_queued("user_abc", %{"queue_depth" => 2})
      assert captured().event == "chat_message_queued"

      :ok = ChatAnalytics.message_received("user_abc")
      assert captured().event == "chat_message_received"

      :ok = ChatAnalytics.turn_failed("user_abc", %{"reason" => "provider_unavailable"})
      assert captured().event == "chat_turn_failed"

      :ok = ChatAnalytics.tool_called("user_abc", %{"tool_name" => "read_file"})
      assert captured().event == "chat_tool_called"

      :ok = ChatAnalytics.voice_started("user_abc")
      assert captured().event == "chat_voice_started"

      :ok = ChatAnalytics.voice_ended("user_abc", %{"duration_ms" => 4_000})
      assert captured().event == "chat_voice_ended"
    end
  end

  describe "length_bucket/1" do
    test "message size reads as a bucket rather than as content" do
      assert ChatAnalytics.length_bucket("hello") == "under_100"
      assert ChatAnalytics.length_bucket(String.duplicate("a", 500)) == "under_1k"
      assert ChatAnalytics.length_bucket(String.duplicate("a", 5_000)) == "under_8k"
      assert ChatAnalytics.length_bucket(String.duplicate("a", 9_000)) == "over_8k"
    end
  end
end
