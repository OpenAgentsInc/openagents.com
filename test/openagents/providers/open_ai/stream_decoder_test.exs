defmodule OpenAgents.Providers.OpenAI.StreamDecoderTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Providers.OpenAI.StreamDecoder
  alias OpenAgents.Providers.ProviderEvent.ToolCall

  test "decodes fragmented lifecycle, text, tool, usage, and completion events" do
    stream =
      frame(%{"type" => "response.created", "response" => %{"id" => "resp_123"}}) <>
        frame(%{"type" => "response.output_text.delta", "delta" => "Hel"}) <>
        frame(%{"type" => "response.output_text.delta", "delta" => "lo"}) <>
        frame(%{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "function_call",
            "id" => "item_1",
            "call_id" => "call_1",
            "name" => "recall_messages",
            "arguments" => ~s({"query":"One"})
          }
        }) <>
        frame(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_123",
            "usage" => %{
              "input_tokens" => 10,
              "output_tokens" => 4,
              "total_tokens" => 14,
              "input_tokens_details" => %{"cached_tokens" => 2},
              "output_tokens_details" => %{"reasoning_tokens" => 1}
            }
          }
        })

    chunks = for <<chunk::binary-size(7) <- stream>>, do: chunk
    remainder_size = rem(byte_size(stream), 7)

    chunks =
      if remainder_size == 0,
        do: chunks,
        else: chunks ++ [binary_part(stream, byte_size(stream) - remainder_size, remainder_size)]

    assert {:ok, decoder, events} = feed_all(chunks)
    assert {:ok, _decoder, final_events} = StreamDecoder.finish(decoder)

    assert events ++ final_events == [
             {:response_started, "resp_123"},
             {:text_delta, "Hel"},
             {:text_delta, "lo"},
             {:tool_call,
              %ToolCall{
                item_id: "item_1",
                call_id: "call_1",
                name: "recall_messages",
                raw_arguments: ~s({"query":"One"})
              }},
             {:usage,
              %{
                "cached_input_tokens" => 2,
                "input_tokens" => 10,
                "output_tokens" => 4,
                "reasoning_output_tokens" => 1,
                "total_tokens" => 14
              }},
             {:response_completed, "resp_123"}
           ]
  end

  test "decodes reasoning summary and reasoning text deltas as reasoning events" do
    stream =
      frame(%{"type" => "response.created", "response" => %{"id" => "resp_r"}}) <>
        frame(%{"type" => "response.reasoning_summary_text.delta", "delta" => "Weighing "}) <>
        frame(%{"type" => "response.reasoning_text.delta", "delta" => "options."}) <>
        frame(%{"type" => "response.output_text.delta", "delta" => "Done."}) <>
        frame(%{"type" => "response.completed", "response" => %{"id" => "resp_r"}})

    assert {:ok, decoder, events} = feed_all([stream])
    assert {:ok, _decoder, final_events} = StreamDecoder.finish(decoder)

    assert events ++ final_events == [
             {:response_started, "resp_r"},
             {:reasoning_delta, "Weighing "},
             {:reasoning_delta, "options."},
             {:text_delta, "Done."},
             {:response_completed, "resp_r"}
           ]
  end

  test "rejects malformed JSON and a completed response with a changed ID" do
    assert {:error, :invalid_provider_event} =
             StreamDecoder.feed(StreamDecoder.new(), "data: {not-json}\n\n")

    assert {:ok, started, _events} =
             StreamDecoder.feed(
               StreamDecoder.new(),
               frame(%{"type" => "response.created", "response" => %{"id" => "resp_one"}})
             )

    assert {:error, :invalid_provider_event} =
             StreamDecoder.feed(
               started,
               frame(%{"type" => "response.completed", "response" => %{"id" => "resp_two"}})
             )
  end

  test "truncated streams and provider cancellation are typed terminal outcomes" do
    assert {:ok, decoder, [{:response_started, "resp_partial"}]} =
             StreamDecoder.feed(
               StreamDecoder.new(),
               frame(%{"type" => "response.created", "response" => %{"id" => "resp_partial"}})
             )

    assert {:error, :truncated_stream} = StreamDecoder.finish(decoder)

    assert {:ok, cancelled, [:cancelled]} =
             StreamDecoder.feed(StreamDecoder.new(), frame(%{"type" => "response.cancelled"}))

    assert {:ok, _decoder, []} = StreamDecoder.finish(cancelled)
  end

  test "provider failures expose a bounded normalized code rather than raw objects" do
    raw = %{
      "type" => "response.failed",
      "response" => %{
        "id" => "resp_failed",
        "error" => %{
          "code" => "rate_limit_exceeded",
          "message" => "private provider detail"
        }
      }
    }

    assert {:ok, decoder,
            [
              {:response_started, "resp_failed"},
              {:failed, {:provider_failed, "rate_limit_exceeded"}}
            ]} =
             StreamDecoder.feed(StreamDecoder.new(), frame(raw))

    assert {:ok, _decoder, []} = StreamDecoder.finish(decoder)
  end

  defp feed_all(chunks) do
    Enum.reduce_while(chunks, {:ok, StreamDecoder.new(), []}, fn chunk, {:ok, decoder, events} ->
      case StreamDecoder.feed(decoder, chunk) do
        {:ok, next_decoder, next_events} ->
          {:cont, {:ok, next_decoder, events ++ next_events}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp frame(value), do: "data: " <> Jason.encode!(value) <> "\n\n"
end
