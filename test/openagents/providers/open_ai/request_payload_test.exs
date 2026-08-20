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
end
