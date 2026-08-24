defmodule OpenAgents.Providers.OpenRouter.StreamDecoderTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Providers.OpenRouter.StreamDecoder
  alias OpenAgents.Providers.ProviderEvent.ToolCall

  test "decodes a fragmented text stream into lifecycle, text, usage, and completion" do
    stream =
      frame(%{"id" => "gen-1", "choices" => [%{"delta" => %{"content" => "Hel"}}]}) <>
        ": OPENROUTER PROCESSING\n\n" <>
        frame(%{"id" => "gen-1", "choices" => [%{"delta" => %{"content" => "lo"}}]}) <>
        frame(%{
          "id" => "gen-1",
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]
        }) <>
        frame(%{
          "id" => "gen-1",
          "choices" => [],
          "usage" => %{"prompt_tokens" => 9, "completion_tokens" => 2, "total_tokens" => 11}
        }) <> "data: [DONE]\n\n"

    assert {:ok, decoder, events} = feed_in_pieces(stream, 5)
    assert {:ok, _decoder, final} = StreamDecoder.finish(decoder)

    assert events ++ final == [
             {:response_started, "gen-1"},
             {:text_delta, "Hel"},
             {:text_delta, "lo"},
             {:usage, %{"input_tokens" => 9, "output_tokens" => 2, "total_tokens" => 11}},
             {:response_completed, "gen-1"}
           ]
  end

  test "decodes reasoning deltas alongside text, in stream order" do
    stream =
      frame(%{"id" => "gen-r", "choices" => [%{"delta" => %{"reasoning" => "Consider "}}]}) <>
        frame(%{
          "id" => "gen-r",
          "choices" => [%{"delta" => %{"reasoning" => "the request.", "content" => "Hi"}}]
        }) <>
        frame(%{"id" => "gen-r", "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}) <>
        "data: [DONE]\n\n"

    assert {:ok, decoder, events} = feed_in_pieces(stream, 7)
    assert {:ok, _decoder, final} = StreamDecoder.finish(decoder)

    assert events ++ final == [
             {:response_started, "gen-r"},
             {:reasoning_delta, "Consider "},
             {:reasoning_delta, "the request."},
             {:text_delta, "Hi"},
             {:response_completed, "gen-r"}
           ]
  end

  test "carries an upstream reasoning_content spelling and ignores structured reasoning" do
    stream =
      frame(%{
        "id" => "gen-rc",
        "choices" => [%{"delta" => %{"reasoning_content" => "Thinking."}}]
      }) <>
        frame(%{
          "id" => "gen-rc",
          "choices" => [
            %{"delta" => %{"reasoning" => %{"detail" => "opaque"}, "content" => "Ok"}}
          ]
        }) <>
        frame(%{"id" => "gen-rc", "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]})

    assert {:ok, decoder, events} = feed_in_pieces(stream, 9)
    assert {:ok, _decoder, final} = StreamDecoder.finish(decoder)

    assert events ++ final == [
             {:response_started, "gen-rc"},
             {:reasoning_delta, "Thinking."},
             {:text_delta, "Ok"},
             {:response_completed, "gen-rc"}
           ]
  end

  test "accumulates tool-call fragments and emits them whole at the end" do
    stream =
      frame(%{
        "id" => "gen-2",
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_1",
                  "function" => %{"name" => "delegate", "arguments" => "{\"pro"}
                }
              ]
            }
          }
        ]
      }) <>
        frame(%{
          "id" => "gen-2",
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "mpt\":\"go\"}"}}]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        })

    assert {:ok, decoder, events} = feed_in_pieces(stream, 11)
    assert {:ok, _decoder, final} = StreamDecoder.finish(decoder)

    assert events == [{:response_started, "gen-2"}]

    assert final == [
             {:tool_call,
              %ToolCall{
                item_id: "call_1",
                call_id: "call_1",
                name: "delegate",
                raw_arguments: "{\"prompt\":\"go\"}"
              }},
             {:response_completed, "gen-2"}
           ]
  end

  test "reports a provider error and closes without a completion" do
    stream = frame(%{"error" => %{"code" => "model_not_found", "message" => "no such model"}})

    assert {:ok, decoder, events} = StreamDecoder.feed(StreamDecoder.new(), stream)
    assert events == [{:failed, {:provider_failed, "model_not_found"}}]
    assert {:ok, _decoder, []} = StreamDecoder.finish(decoder)
  end

  test "refuses a stream that ends without a finish reason" do
    stream = frame(%{"id" => "gen-3", "choices" => [%{"delta" => %{"content" => "Half"}}]})

    assert {:ok, decoder, [{:response_started, "gen-3"}, {:text_delta, "Half"}]} =
             StreamDecoder.feed(StreamDecoder.new(), stream)

    assert StreamDecoder.finish(decoder) == {:error, :truncated_stream}
  end

  test "refuses a frame that is not JSON" do
    assert StreamDecoder.feed(StreamDecoder.new(), "data: {not json\n\n") ==
             {:error, :invalid_provider_event}
  end

  defp feed_in_pieces(stream, size) do
    stream
    |> pieces(size)
    |> Enum.reduce({:ok, StreamDecoder.new(), []}, fn piece, {:ok, decoder, events} ->
      assert {:ok, next, more} = StreamDecoder.feed(decoder, piece)
      {:ok, next, events ++ more}
    end)
  end

  defp pieces(stream, size) do
    Stream.unfold(stream, fn
      "" -> nil
      rest -> {binary_part(rest, 0, min(size, byte_size(rest))), cut(rest, size)}
    end)
    |> Enum.to_list()
  end

  defp cut(rest, size) when byte_size(rest) <= size, do: ""
  defp cut(rest, size), do: binary_part(rest, size, byte_size(rest) - size)

  defp frame(payload), do: "data: " <> Jason.encode!(payload) <> "\n\n"
end
