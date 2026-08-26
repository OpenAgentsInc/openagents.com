defmodule OpenAgents.Providers.OpenRouterTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Providers.{OpenRouter, Request}

  setup {Req.Test, :verify_on_exit!}

  defp request do
    %Request{
      model_id: "z-ai/glm-5.3-flash",
      instructions: "Remain OpenAgents.",
      input: [%{role: "user", content: "Say hello."}]
    }
  end

  defp collect(options) do
    parent = self()
    result = OpenRouter.stream(request(), &send(parent, {:event, &1}), options)
    {result, drain([])}
  end

  defp drain(events) do
    receive do
      {:event, event} -> drain([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  test "sends the payload with the server's credential and emits the decoded stream" do
    test_process = self()

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_process, {:outbound, Plug.Conn.get_req_header(conn, "authorization"), body})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse_stream())
    end)

    assert {:ok, events} =
             collect(
               api_key: "sentinel-openrouter-key",
               request_options: [plug: {Req.Test, __MODULE__}]
             )

    assert_received {:outbound, ["Bearer sentinel-openrouter-key"], body}
    assert Jason.decode!(body)["model"] == "z-ai/glm-5.3-flash"

    assert events == [
             {:response_started, "gen-1"},
             {:text_delta, "Hello."},
             {:usage, %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}},
             {:response_completed, "gen-1"}
           ]
  end

  test "an HTTP failure is a bounded reason, not a stream" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "slow down") end)

    assert {{:error, {:http_status, 429}}, []} =
             collect(
               api_key: "sentinel-openrouter-key",
               request_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "a missing credential is refused before any request is made" do
    assert {{:error, :missing_api_key}, []} = collect([])
  end

  defp sse_stream do
    frames = [
      %{"id" => "gen-1", "choices" => [%{"delta" => %{"content" => "Hello."}}]},
      %{"id" => "gen-1", "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]},
      %{
        "id" => "gen-1",
        "choices" => [],
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 1, "total_tokens" => 4}
      }
    ]

    Enum.map_join(frames, "", &("data: " <> Jason.encode!(&1) <> "\n\n")) <> "data: [DONE]\n\n"
  end

  describe "how many tokens the answer may take" do
    test "comes from the model's catalog entry, not a literal in this module" do
      # GLM 5.3 Flash is a reasoning model: its thinking is charged against this
      # allowance before a word of the answer is. Hardcoded at 4,096, a child
      # agent with a real task spent the whole budget reasoning and returned an
      # empty 200 after three minutes, which read as the proxy having failed.
      request = %Request{
        model_id: "z-ai/glm-5.3-flash",
        instructions: "Be brief.",
        input: [%{role: "user", content: "hello"}],
        max_output: 64_000
      }

      assert OpenRouter.request_payload(request)[:max_tokens] == 64_000
    end

    test "defaults to a figure a caller that names none still works on" do
      request = %Request{
        model_id: "z-ai/glm-5.3-flash",
        instructions: "Be brief.",
        input: [%{role: "user", content: "hello"}]
      }

      assert OpenRouter.request_payload(request)[:max_tokens] == 4_096
    end
  end
end
