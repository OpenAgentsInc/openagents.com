defmodule OpenAgents.Providers.OpenRouter.RequestPayloadTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Providers.{OpenRouter, Request, ToolDefinition, ToolOutput}

  test "carries the provider model, the system text, and the turns in order" do
    request = %Request{
      model_id: "z-ai/glm-5.3-flash",
      instructions: "  Remain OpenAgents.  ",
      input: [
        %{role: "user", content: "Write a file."},
        %{role: "assistant", content: "Which one?"},
        %{role: "developer", content: "Any of them."}
      ]
    }

    payload = OpenRouter.request_payload(request)

    assert payload.model == "z-ai/glm-5.3-flash"
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
      model_id: "z-ai/glm-5.3-flash",
      instructions: "",
      input: [%{role: "user", content: "Hello."}]
    }

    assert OpenRouter.request_payload(request).messages == [
             %{role: "user", content: "Hello."}
           ]
  end

  test "preserves multimodal user content" do
    image_url = "data:image/png;base64,iVBORw0KGgo="

    request = %Request{
      model_id: "z-ai/glm-5.3-flash",
      instructions: "",
      input: [
        %{
          role: "user",
          content: [
            %{type: "text", text: "Describe this image."},
            %{type: "image_url", image_url: %{url: image_url}}
          ]
        }
      ]
    }

    assert OpenRouter.request_payload(request).messages == [
             %{
               role: "user",
               content: [
                 %{type: "text", text: "Describe this image."},
                 %{type: "image_url", image_url: %{url: image_url}}
               ]
             }
           ]
  end

  test "maps tool definitions to chat-completions functions" do
    request = %Request{
      model_id: "z-ai/glm-5.3-flash",
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

  test "replays an assistant tool call and its output faithfully" do
    request = %Request{
      model_id: "z-ai/glm-5.3-flash",
      instructions: "",
      input: [
        %{role: "user", content: "Read the file."},
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{call_id: "call_read", name: "read_file", arguments: ~s({"path":"a.txt"})}
          ]
        },
        %{role: "user", content: "And then?"}
      ],
      tool_outputs: [
        %ToolOutput{call_id: "call_read", output: %{"content" => "hello"}}
      ]
    }

    assert OpenRouter.request_payload(request).messages == [
             %{role: "user", content: "Read the file."},
             %{
               role: "assistant",
               content: "",
               tool_calls: [
                 %{
                   id: "call_read",
                   type: "function",
                   function: %{name: "read_file", arguments: ~s({"path":"a.txt"})}
                 }
               ]
             },
             # The tool result lands directly after the assistant call it
             # answers, not at the end of the transcript.
             %{
               role: "tool",
               tool_call_id: "call_read",
               content: ~s({"content":"hello"})
             },
             %{role: "user", content: "And then?"}
           ]
  end

  test "carries a tool output as a labelled user turn" do
    request = %Request{
      model_id: "z-ai/glm-5.3-flash",
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
