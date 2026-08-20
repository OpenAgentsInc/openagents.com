defmodule OpenAgents.Voice.OpenAI.EventDecoderTest do
  use ExUnit.Case, async: true
  @moduletag :skip

  alias OpenAgents.Voice.OpenAI.EventDecoder

  test "decodes bounded lifecycle, transcript, usage, and error events" do
    assert {:ok, ready} =
             EventDecoder.decode(%{"type" => "session.updated", "event_id" => "evt-ready"})

    assert ready.kind == :session_ready
    assert ready.payload == %{}

    assert {:ok, user_transcript} =
             EventDecoder.decode(%{
               "type" => "conversation.item.input_audio_transcription.completed",
               "event_id" => "evt-user",
               "item_id" => "item-user",
               "transcript" => "Hello, OpenAgents."
             })

    assert user_transcript.kind == :user_transcript_final
    assert user_transcript.payload["content"] == "Hello, OpenAgents."

    assert {:ok, tool_call} =
             EventDecoder.decode(%{
               "type" => "response.function_call_arguments.done",
               "event_id" => "evt-tool",
               "response_id" => "response-1",
               "item_id" => "item-tool",
               "call_id" => "call-1",
               "name" => "memory_list",
               "arguments" => ~s({"category":"","first":10})
             })

    assert tool_call.kind == :tool_call_requested

    assert tool_call.payload == %{
             "response_id" => "response-1",
             "item_id" => "item-tool",
             "call_id" => "call-1",
             "tool_name" => "memory_list",
             "raw_arguments" => ~s({"category":"","first":10})
           }

    assert {:ok, done} =
             EventDecoder.decode(%{
               "type" => "response.done",
               "event_id" => "evt-done",
               "response" => %{
                 "id" => "response-1",
                 "status" => "completed",
                 "usage" => %{
                   "input_tokens" => 10,
                   "output_tokens" => 5,
                   "total_tokens" => 15,
                   "input_token_details" => %{
                     "text_tokens" => 4,
                     "audio_tokens" => 6,
                     "cached_tokens" => 2,
                     "cached_tokens_details" => %{"audio_tokens" => 2}
                   },
                   "output_token_details" => %{"text_tokens" => 1, "audio_tokens" => 4},
                   "private_detail" => "not admitted"
                 }
               }
             })

    assert done.payload["usage"]["input_tokens"] == 10
    assert done.payload["usage"]["input_text_tokens"] == 4
    assert done.payload["usage"]["input_audio_tokens"] == 6
    assert done.payload["usage"]["input_cached_audio_tokens"] == 2
    assert done.payload["usage"]["output_audio_tokens"] == 4
    refute Map.has_key?(done.payload["usage"], "private_detail")

    assert {:ok, error} =
             EventDecoder.decode(%{
               "type" => "error",
               "error" => %{"code" => "rate limit", "message" => "private provider text"}
             })

    assert error.payload == %{"code" => "rate_limit"}
    refute inspect(error) =~ "private provider text"
  end

  test "decodes transcript deltas and drops malformed ones" do
    assert {:ok, assistant_delta} =
             EventDecoder.decode(%{
               "type" => "response.output_audio_transcript.delta",
               "event_id" => "evt-delta-1",
               "item_id" => "item-1",
               "delta" => "Hello"
             })

    assert assistant_delta.kind == :assistant_transcript_delta
    assert assistant_delta.payload == %{"item_id" => "item-1", "delta" => "Hello"}

    assert {:ok, user_delta} =
             EventDecoder.decode(%{
               "type" => "conversation.item.input_audio_transcription.delta",
               "item_id" => "item-2",
               "delta" => "What is"
             })

    assert user_delta.kind == :user_transcript_delta
    assert user_delta.payload == %{"item_id" => "item-2", "delta" => "What is"}

    assert :ignore =
             EventDecoder.decode(%{
               "type" => "response.output_audio_transcript.delta",
               "item_id" => "item-1",
               "delta" => ""
             })

    assert :ignore =
             EventDecoder.decode(%{
               "type" => "response.output_audio_transcript.delta",
               "delta" => "missing item"
             })
  end

  test "ignores the benign cancel-after-completion provider error" do
    assert :ignore =
             EventDecoder.decode(%{
               "type" => "error",
               "error" => %{"code" => "response_cancel_not_active"}
             })
  end

  test "ignores unknown and malformed non-critical events" do
    assert :ignore = EventDecoder.decode(%{"type" => "rate_limits.updated"})

    assert :ignore =
             EventDecoder.decode(%{"type" => "response.output_audio.delta", "delta" => "raw"})

    assert :ignore =
             EventDecoder.decode(%{
               "type" => "response.output_audio_transcript.done",
               "item_id" => "item-1",
               "transcript" => ""
             })

    assert :ignore =
             EventDecoder.decode(%{
               "type" => "response.output_audio_transcript.done",
               "item_id" => "item-1",
               "transcript" => "Missing response identity"
             })

    assert :ignore =
             EventDecoder.decode(%{
               "type" => "conversation.item.input_audio_transcription.completed",
               "item_id" => "item-user",
               "transcript" => ""
             })

    assert {:error, :invalid_provider_event} = EventDecoder.decode(%{"unexpected" => true})

    assert {:error, :invalid_provider_event} =
             EventDecoder.decode(%{
               "type" => "response.function_call_arguments.done",
               "response_id" => "response-1",
               "item_id" => "item-tool",
               "call_id" => "call-1",
               "name" => "memory_list",
               "arguments" => ""
             })
  end
end
