defmodule OpenAgents.Chat.OpenRouter.ResponsesStreamDecoderTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Chat.OpenRouter.ResponsesStreamDecoder

  test "assembles completed tool output from item events and argument deltas" do
    reasoning = %{
      "type" => "reasoning",
      "id" => "rs_test",
      "status" => "completed",
      "summary" => [%{"type" => "summary_text", "text" => "Use the demo tool."}],
      "encrypted_content" => "encrypted-reasoning"
    }

    function_call = %{
      "type" => "function_call",
      "id" => "fc_test",
      "call_id" => "call_test",
      "name" => "get_demo_time",
      "status" => "completed"
    }

    stream =
      frame(%{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => reasoning
      }) <>
        frame(%{
          "type" => "response.output_item.added",
          "output_index" => 1,
          "item" => Map.put(function_call, "arguments", "")
        }) <>
        frame(%{
          "type" => "response.function_call_arguments.delta",
          "item_id" => "fc_test",
          "delta" => "{"
        }) <>
        frame(%{
          "type" => "response.function_call_arguments.delta",
          "item_id" => "fc_test",
          "delta" => "}"
        }) <>
        frame(%{
          "type" => "response.output_item.done",
          "output_index" => 1,
          "item" => function_call
        }) <>
        frame(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_test",
            "object" => "response",
            "status" => "completed",
            "model" => "stealth/ox-alpha"
          }
        })

    assert {:ok, state, []} = ResponsesStreamDecoder.feed(ResponsesStreamDecoder.new(), stream)

    expected_call = Map.put(function_call, "arguments", "{}")

    assert {:ok,
            %{
              "output" => [^reasoning, ^expected_call],
              "reasoning_items" => [^reasoning],
              "tool_calls" => [
                %{
                  "id" => "fc_test",
                  "call_id" => "call_test",
                  "name" => "get_demo_time",
                  "arguments" => "{}"
                }
              ]
            }} = ResponsesStreamDecoder.finish(state)
  end

  test "returns structured failure and incomplete response details" do
    failed =
      frame(%{
        "type" => "response.failed",
        "error_type" => "authentication",
        "response" => %{
          "id" => "resp_failed",
          "error" => %{"code" => "server_error", "message" => "Invalid credentials"}
        }
      })

    assert {:error, {:provider_error, "authentication", "Invalid credentials"}} =
             ResponsesStreamDecoder.feed(ResponsesStreamDecoder.new(), failed)

    incomplete =
      frame(%{
        "type" => "response.incomplete",
        "response" => %{
          "id" => "resp_incomplete",
          "incomplete_details" => %{"reason" => "max_output_tokens"}
        }
      })

    assert {:error, {:provider_error, "max_output_tokens", nil}} =
             ResponsesStreamDecoder.feed(ResponsesStreamDecoder.new(), incomplete)
  end

  defp frame(value), do: "data: " <> Jason.encode!(value) <> "\n\n"
end
