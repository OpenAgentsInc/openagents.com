defmodule OpenAgentsWeb.ResponsesControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Providers.{
    FailingTestProvider,
    RecordingTestProvider,
    ToolCallingTestProvider,
    UnconfiguredTestProvider
  }

  # The default model rides the Vercel gateway lane; swapping the lane's
  # adapter is how a test decides what "real inference" answers with.
  defp swap_lane(adapter) do
    previous = Application.get_env(:openagents, :vercel_gateway_provider)
    Application.put_env(:openagents, :vercel_gateway_provider, adapter)
    on_exit(fn -> Application.put_env(:openagents, :vercel_gateway_provider, previous) end)
  end

  describe "the non-streaming response object" do
    setup do
      swap_lane(RecordingTestProvider)
      :ok
    end

    test "answers an anonymous caller from the provider", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/responses", %{input: "hello"})

      assert %{
               "object" => "response",
               "status" => "completed",
               "model" => "gemini-3.7-flash",
               "output" => [message],
               "usage" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             } = json_response(conn, 200)

      assert %{
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "content" => [%{"type" => "output_text", "text" => "Recorded."}]
             } = message
    end

    test "carries the caller's instructions and input items to the provider", %{conn: conn} do
      Application.put_env(:openagents, :test_recording_provider_observer, self())
      on_exit(fn -> Application.delete_env(:openagents, :test_recording_provider_observer) end)

      conn =
        post(conn, ~p"/api/v1/responses", %{
          instructions: "Answer in French.",
          input: [
            %{role: "user", content: [%{type: "input_text", text: "bonjour"}]},
            %{role: "assistant", content: "salut"},
            %{role: "user", content: "encore"}
          ],
          max_output_tokens: 128
        })

      assert json_response(conn, 200)
      assert_receive {:recorded_request, _id, request}
      assert request.instructions == "Answer in French."
      assert request.max_output == 128

      assert request.input == [
               %{role: "user", content: "bonjour"},
               %{role: "assistant", content: "salut"},
               %{role: "user", content: "encore"}
             ]
    end

    test "reports a provider failure as a failed response object", %{conn: conn} do
      swap_lane(FailingTestProvider)

      conn = post(conn, ~p"/api/v1/responses", %{input: "hello"})

      assert %{"status" => "failed", "error" => %{"code" => "provider_failed"}} =
               json_response(conn, 200)
    end
  end

  describe "streaming" do
    setup do
      swap_lane(RecordingTestProvider)
      :ok
    end

    test "streams the semantic event sequence around the provider's deltas", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/responses", %{input: "hello", stream: true})

      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "text/event-stream"
      body = response(conn, 200)

      for {event, at} <- Enum.with_index(~w(
            response.created
            response.output_item.added
            response.content_part.added
            response.output_text.delta
            response.output_text.done
            response.content_part.done
            response.output_item.done
            response.completed
          )) do
        assert body =~ "event: " <> event
        assert body =~ ~s("sequence_number":#{at})
      end

      assert body =~ ~s("delta":"Recorded.")
      assert body =~ ~s("text":"Recorded.")
      assert body =~ ~s("input_tokens":4)
      refute body =~ "Acknowledged"
    end

    test "a provider failure mid-stream arrives as response.failed", %{conn: conn} do
      swap_lane(FailingTestProvider)

      conn = post(conn, ~p"/api/v1/responses", %{input: "hello", stream: true})
      body = response(conn, 200)

      assert body =~ ~s("delta":"half an ")
      assert body =~ "event: response.failed"
      assert body =~ ~s("code":"provider_failed")
      refute body =~ "response.completed"
    end
  end

  describe "refusals, in the envelope" do
    test "a request with no input", %{conn: conn} do
      swap_lane(RecordingTestProvider)
      conn = post(conn, ~p"/api/v1/responses", %{})

      body = json_response(conn, 422)
      assert body["code"] == "validation_failed"
      assert body["errors"] == %{"input" => ["is required"]}
    end

    test "a model outside the catalog", %{conn: conn} do
      swap_lane(RecordingTestProvider)
      conn = post(conn, ~p"/api/v1/responses", %{input: "hi", model: "gpt-9-imaginary"})

      body = json_response(conn, 422)
      assert body["errors"]["model"] == ["`gpt-9-imaginary` is not in the catalog"]
    end

    test "a lane with no configured credential", %{conn: conn} do
      swap_lane(UnconfiguredTestProvider)
      conn = post(conn, ~p"/api/v1/responses", %{input: "hi"})

      body = json_response(conn, 503)
      assert body["code"] == "model_unavailable"
    end
  end

  describe "tools through the surface" do
    setup do
      swap_lane(ToolCallingTestProvider)
      :ok
    end

    @tools [
      %{
        type: "function",
        name: "read_conversation",
        description: "Read a conversation back.",
        parameters: %{type: "object", properties: %{}}
      }
    ]

    test "a declared tool comes back as a function_call output item", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/responses", %{input: "read it", tools: @tools})

      assert %{"output" => [_message, call]} = json_response(conn, 200)

      assert %{
               "type" => "function_call",
               "call_id" => "call_1",
               "name" => "read_conversation",
               "arguments" => ~s({"max_turns":4}),
               "status" => "completed"
             } = call
    end

    test "streams the function_call item with its own events", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/responses", %{input: "read it", tools: @tools, stream: true})
      body = response(conn, 200)

      assert body =~ "event: response.function_call_arguments.done"
      assert body =~ ~s("name":"read_conversation")
      assert body =~ ~s("output_index":1)
      assert body =~ "event: response.completed"
    end

    test "replayed calls and outputs reach the provider, and it answers from them", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/responses", %{
          input: [
            %{role: "user", content: "read it"},
            %{
              type: "function_call",
              call_id: "call_1",
              name: "read_conversation",
              arguments: ~s({"max_turns":4})
            },
            %{type: "function_call_output", call_id: "call_1", output: "four turns of text"}
          ],
          tools: @tools
        })

      assert %{"output" => [message]} = json_response(conn, 200)
      assert %{"content" => [%{"text" => "The tool said: four turns of text"}]} = message
    end
  end
end
