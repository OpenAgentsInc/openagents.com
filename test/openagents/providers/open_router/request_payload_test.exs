defmodule OpenAgents.Providers.OpenRouter.RequestPayloadTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Providers.{OpenRouter, Request, ToolDefinition, ToolOutput}

  test "carries the provider model, the system text, and the turns in order" do
    request = %Request{
      model_id: "stealth/ox-alpha",
      instructions: "  Remain OpenAgents.  ",
      input: [
        %{role: "user", content: "Write a file."},
        %{role: "assistant", content: "Which one?"},
        %{role: "developer", content: "Any of them."}
      ]
    }

    payload = OpenRouter.request_payload(request)

    assert payload.model == "stealth/ox-alpha"
    assert payload.stream == true
    assert payload.stream_options == %{include_usage: true}
    refute Map.has_key?(payload, :tools)

    assert payload.messages == [
             %{role: "system", content: "Remain OpenAgents."},
             %{role: "user", content: "Write a file."},
             %{role: "assistant", content: "Which one?"},
             # `developer` is not a chat-completions role; it is carried as a
             # user turn rather than dropped or sent as-is.
             %{role: "user", content: "Any of them."}
           ]
  end

  test "sends no system message when the request has no instructions" do
    request = %Request{
      model_id: "stealth/ox-alpha",
      instructions: "",
      input: [%{role: "user", content: "Hello."}]
    }

    assert OpenRouter.request_payload(request).messages == [
             %{role: "user", content: "Hello."}
           ]
  end

  test "maps tool definitions to chat-completions functions" do
    request = %Request{
      model_id: "stealth/ox-alpha",
      instructions: "",
      input: [%{role: "user", content: "Search."}],
      tool_definitions: [
        %ToolDefinition{
          name: "conversation_search",
          description: "Search the transcript",
          strict: true,
          input_schema: %{"type" => "object", "properties" => %{}}
        }
      ]
    }

    assert OpenRouter.request_payload(request).tools == [
             %{
               type: "function",
               function: %{
                 name: "conversation_search",
                 description: "Search the transcript",
                 parameters: %{"type" => "object", "properties" => %{}}
               }
             }
           ]
  end

  test "carries a tool output as a labelled user turn" do
    request = %Request{
      model_id: "stealth/ox-alpha",
      instructions: "",
      input: [%{role: "user", content: "Search."}],
      tool_outputs: [
        %ToolOutput{call_id: "call_1", output: %{"status" => "succeeded"}}
      ]
    }

    assert OpenRouter.request_payload(request).messages == [
             %{role: "user", content: "Search."},
             %{
               role: "user",
               content: ~s(Tool result for call_1: {"status":"succeeded"})
             }
           ]
  end
end
