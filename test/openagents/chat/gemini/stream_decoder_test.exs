defmodule OpenAgents.Chat.Gemini.StreamDecoderTest do
  @moduledoc """
  The Gemini wire shapes that would otherwise be decoded wrong.

  Each test here is a shape the live API actually produces, captured against
  `gemini-3.7-flash`: reasoning arriving as `thought: true` parts beside the
  answer, usage repeated cumulatively on every chunk with counts missing until
  they are measured, and a stream whose only terminal marker is `finishReason`.
  """
  use ExUnit.Case, async: true

  alias OpenAgents.Chat.Gemini.StreamDecoder

  defp frame(payload), do: "data: " <> Jason.encode!(payload) <> "\n\n"

  defp part(text, opts \\ []) do
    if Keyword.get(opts, :thought, false),
      do: %{"text" => text, "thought" => true},
      else: %{"text" => text}
  end

  defp chunk(parts, extra \\ %{}) do
    Map.merge(
      %{"candidates" => [%{"content" => %{"parts" => parts, "role" => "model"}, "index" => 0}]},
      extra
    )
  end

  defp feed_all(state, chunks) do
    Enum.reduce(chunks, {state, []}, fn chunk, {state, events} ->
      {:ok, state, new_events} = StreamDecoder.feed(state, chunk)
      {state, events ++ new_events}
    end)
  end

  describe "content and reasoning" do
    test "tells a thought part from an answer part in the same stream" do
      stream =
        frame(chunk([part("Working it out.", thought: true)])) <>
          frame(chunk([part("There are 9.")], %{"modelVersion" => "gemini-3.7-flash"})) <>
          frame(%{"candidates" => [%{"content" => %{"parts" => []}, "finishReason" => "STOP"}]})

      {state, events} = feed_all(StreamDecoder.new(model: "gemini-3.7-flash"), [stream])

      assert events == [
               {:reasoning_delta, "Working it out."},
               {:text_delta, "There are 9."}
             ]

      assert {:ok, %{"assistant_content" => "There are 9."}} = StreamDecoder.finish(state)
    end

    test "a signature-only part is not an empty delta" do
      stream =
        frame(chunk([%{"text" => "", "thoughtSignature" => "opaque"}, %{"thought" => true}]))

      {_state, events} = feed_all(StreamDecoder.new(model: "m"), [stream])

      assert events == []
    end

    test "a chunk carrying no candidates is metadata, not a decode failure" do
      state = StreamDecoder.new(model: "m")

      assert {:ok, _state, []} =
               StreamDecoder.feed(state, frame(%{"usageMetadata" => %{"promptTokenCount" => 3}}))

      assert {:ok, _state, []} = StreamDecoder.feed(state, frame(%{"candidates" => nil}))
    end

    test "separates reasoning from the answer in the completion" do
      stream =
        frame(chunk([part("Think.", thought: true)])) <>
          frame(chunk([part("Answer.")])) <>
          frame(%{
            "candidates" => [%{"content" => %{"parts" => []}, "finishReason" => "STOP"}]
          })

      {state, _events} = feed_all(StreamDecoder.new(model: "gemini-3.7-flash"), [stream])

      assert {:ok, completion} = StreamDecoder.finish(state)
      assert completion["assistant_content"] == "Answer."
      assert completion["reasoning_summary"] == "Think."
      assert completion["finish_reason"] == "STOP"
      assert completion["model"] == "gemini-3.7-flash"
      assert is_binary(completion["assistant_message_id"])
    end
  end

  describe "framing" do
    test "decodes a token split across two transport chunks exactly once" do
      whole =
        frame(chunk([part("hello ")])) <>
          frame(chunk([part("world")])) <>
          frame(%{"candidates" => [%{"content" => %{"parts" => []}, "finishReason" => "STOP"}]})

      split = div(byte_size(whole), 2)
      <<head::binary-size(^split), tail::binary>> = whole

      {state, events} = feed_all(StreamDecoder.new(model: "m"), [head, tail])

      assert events == [{:text_delta, "hello "}, {:text_delta, "world"}]
      assert {:ok, %{"assistant_content" => "hello world"}} = StreamDecoder.finish(state)
    end

    test "a byte-at-a-time stream decodes to the same events as one chunk" do
      whole =
        frame(chunk([part("abc")])) <>
          frame(%{"candidates" => [%{"content" => %{"parts" => []}, "finishReason" => "STOP"}]})

      bytes = for <<byte <- whole>>, do: <<byte>>
      {state, events} = feed_all(StreamDecoder.new(model: "m"), bytes)

      assert events == [{:text_delta, "abc"}]
      assert {:ok, %{"assistant_content" => "abc"}} = StreamDecoder.finish(state)
    end
  end

  describe "usage" do
    test "maps usageMetadata onto the counts a turn stores, thoughts included" do
      stream =
        frame(chunk([part("hi")])) <>
          frame(%{
            "candidates" => [%{"content" => %{"parts" => []}, "finishReason" => "STOP"}],
            "usageMetadata" => %{
              "promptTokenCount" => 17,
              "candidatesTokenCount" => 14,
              "totalTokenCount" => 304,
              "thoughtsTokenCount" => 273,
              "cachedContentTokenCount" => 5
            }
          })

      {state, _events} = feed_all(StreamDecoder.new(model: "m"), [stream])
      assert {:ok, completion} = StreamDecoder.finish(state)

      assert completion["usage"] == %{
               "input_tokens" => 17,
               "output_tokens" => 14,
               "total_tokens" => 304,
               "output_tokens_details" => %{"reasoning_tokens" => 273},
               "input_tokens_details" => %{"cached_tokens" => 5}
             }
    end

    test "a count the provider never reported stays absent rather than zero" do
      # `thinkingLevel: "low"` really does answer with no `thoughtsTokenCount`
      # at all. A zero there would read as "this turn did not reason", which is
      # a different claim from "nobody counted".
      stream =
        frame(chunk([part("hi")])) <>
          frame(%{
            "candidates" => [%{"content" => %{"parts" => []}, "finishReason" => "STOP"}],
            "usageMetadata" => %{
              "promptTokenCount" => 8,
              "candidatesTokenCount" => 3,
              "totalTokenCount" => 11
            }
          })

      {state, _events} = feed_all(StreamDecoder.new(model: "m"), [stream])
      assert {:ok, completion} = StreamDecoder.finish(state)

      refute Map.has_key?(completion["usage"], "output_tokens_details")
      refute Map.has_key?(completion["usage"], "input_tokens_details")
      assert completion["usage"]["total_tokens"] == 11
    end

    test "cumulative repeats replace rather than accumulate" do
      # Every chunk repeats the whole measurement. Summing them would report a
      # turn's tokens once per chunk.
      stream =
        frame(
          chunk([part("a")], %{
            "usageMetadata" => %{"promptTokenCount" => 17, "totalTokenCount" => 17}
          })
        ) <>
          frame(
            chunk([part("b")], %{
              "usageMetadata" => %{
                "promptTokenCount" => 17,
                "candidatesTokenCount" => 13,
                "totalTokenCount" => 303,
                "thoughtsTokenCount" => 273
              }
            })
          ) <>
          frame(%{
            "candidates" => [%{"content" => %{"parts" => []}, "finishReason" => "STOP"}],
            "usageMetadata" => %{
              "promptTokenCount" => 17,
              "candidatesTokenCount" => 14,
              "totalTokenCount" => 304,
              "thoughtsTokenCount" => 273
            }
          })

      {state, _events} = feed_all(StreamDecoder.new(model: "m"), [stream])
      assert {:ok, completion} = StreamDecoder.finish(state)

      assert completion["usage"]["input_tokens"] == 17
      assert completion["usage"]["output_tokens"] == 14
      assert completion["usage"]["total_tokens"] == 304
    end

    test "a later chunk that omits a count keeps the one that reported it" do
      stream =
        frame(
          chunk([part("a")], %{
            "usageMetadata" => %{
              "promptTokenCount" => 9,
              "candidatesTokenCount" => 4,
              "thoughtsTokenCount" => 100,
              "totalTokenCount" => 113
            }
          })
        ) <>
          frame(%{
            "candidates" => [%{"content" => %{"parts" => []}, "finishReason" => "STOP"}],
            "usageMetadata" => %{"trafficType" => "ON_DEMAND"}
          })

      {state, _events} = feed_all(StreamDecoder.new(model: "m"), [stream])
      assert {:ok, completion} = StreamDecoder.finish(state)

      assert completion["usage"]["output_tokens_details"] == %{"reasoning_tokens" => 100}
      assert completion["usage"]["total_tokens"] == 113
    end

    test "a stream that reported no usage carries no usage" do
      stream =
        frame(chunk([part("hi")])) <>
          frame(%{"candidates" => [%{"content" => %{"parts" => []}, "finishReason" => "STOP"}]})

      {state, _events} = feed_all(StreamDecoder.new(model: "m"), [stream])
      assert {:ok, completion} = StreamDecoder.finish(state)

      refute Map.has_key?(completion, "usage")
    end
  end

  describe "failure" do
    test "a stream with no finishReason is truncated, not a short answer" do
      {state, _events} =
        feed_all(StreamDecoder.new(model: "m"), [frame(chunk([part("half an ans")]))])

      assert {:error, :stream_interrupted} = StreamDecoder.finish(state)
    end

    test "an error frame becomes the failure its status names" do
      for {status, expected} <- [
            {"RESOURCE_EXHAUSTED", :rate_limited},
            {"UNAVAILABLE", :service_unavailable},
            {"INVALID_ARGUMENT", :provider_unavailable}
          ] do
        payload = frame(%{"error" => %{"code" => 400, "message" => "no", "status" => status}})

        assert {:error, ^expected} = StreamDecoder.feed(StreamDecoder.new(model: "m"), payload)
      end
    end

    test "an unparsable frame is refused rather than skipped" do
      assert {:error, :invalid_response} =
               StreamDecoder.feed(StreamDecoder.new(model: "m"), "data: {not json\n\n")
    end

    test "a turn that produced neither answer nor reasoning has nothing to store" do
      {state, _events} =
        feed_all(StreamDecoder.new(model: "m"), [
          frame(%{"candidates" => [%{"content" => %{"parts" => []}, "finishReason" => "STOP"}]})
        ])

      assert {:error, :invalid_response} = StreamDecoder.finish(state)
    end

    test "a turn that spent its whole budget thinking keeps its reasoning" do
      stream =
        frame(chunk([part("thinking hard", thought: true)])) <>
          frame(%{"candidates" => [%{"finishReason" => "MAX_TOKENS"}]})

      {state, _events} = feed_all(StreamDecoder.new(model: "m"), [stream])

      assert {:ok, completion} = StreamDecoder.finish(state)
      assert completion["assistant_content"] == ""
      assert completion["reasoning_summary"] == "thinking hard"
      assert completion["finish_reason"] == "MAX_TOKENS"
    end
  end
end
