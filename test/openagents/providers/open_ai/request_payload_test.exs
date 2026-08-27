defmodule OpenAgents.Providers.OpenAI.RequestPayloadTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Providers.{OpenAI, Request, ToolDefinition, ToolOutput}

  test "encodes a serial OpenResponses function-call continuation" do
    request = %Request{
      model_id: "test-model",
      instructions: "Remain OpenAgents.",
      input: [],
      previous_response_id: "resp_previous",
      tool_definitions: [
        %ToolDefinition{
          name: "recall_messages",
          description: "Recall messages",
          strict: true,
          input_schema: %{
            "type" => "object",
            "properties" => %{"query" => %{"type" => "string"}},
            "required" => ["query"],
            "additionalProperties" => false
          }
        }
      ],
      tool_outputs: [
        %ToolOutput{
          call_id: "call_123",
          output: %{"status" => "succeeded", "result" => %{"matches" => []}}
        }
      ]
    }

    payload = OpenAI.request_payload(request)

    assert payload.previous_response_id == "resp_previous"
    assert payload.parallel_tool_calls == false

    assert payload.tools == [
             %{
               type: "function",
               name: "recall_messages",
               description: "Recall messages",
               parameters: %{
                 "type" => "object",
                 "properties" => %{"query" => %{"type" => "string"}},
                 "required" => ["query"],
                 "additionalProperties" => false
               },
               strict: true
             }
           ]

    assert [output] = payload.input
    assert output.type == "function_call_output"
    assert output.call_id == "call_123"

    assert Jason.decode!(output.output) == %{
             "status" => "succeeded",
             "result" => %{"matches" => []}
           }
  end

  test "without a previous response, replays a tool call as its item pair in place" do
    request = %Request{
      model_id: "test-model",
      instructions: "Remain OpenAgents.",
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

    payload = OpenAI.request_payload(request)

    refute Map.has_key?(payload, :previous_response_id)

    assert [
             %{role: "user", content: "Read the file."},
             %{
               type: "function_call",
               call_id: "call_read",
               name: "read_file",
               arguments: ~s({"path":"a.txt"})
             },
             %{type: "function_call_output", call_id: "call_read", output: encoded_output},
             %{role: "user", content: "And then?"}
           ] = payload.input

    assert Jason.decode!(encoded_output) == %{"content" => "hello"}
  end

  test "without a previous response, an output whose call was not replayed still travels" do
    request = %Request{
      model_id: "test-model",
      instructions: "",
      input: [%{role: "user", content: "Continue."}],
      tool_outputs: [
        %ToolOutput{call_id: "call_orphan", output: %{"status" => "succeeded"}}
      ]
    }

    assert [
             %{role: "user", content: "Continue."},
             %{type: "function_call_output", call_id: "call_orphan", output: _output}
           ] = OpenAI.request_payload(request).input
  end

  test "maps multimodal user content to Responses input parts" do
    image_url = "data:image/png;base64,iVBORw0KGgo="

    request = %Request{
      model_id: "test-model",
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

    assert OpenAI.request_payload(request).input == [
             %{
               role: "user",
               content: [
                 %{type: "input_text", text: "Describe this image."},
                 %{type: "input_image", image_url: image_url}
               ]
             }
           ]
  end
end
