defmodule OpenAgentsWeb.ChatTurnControllerTest do
  use OpenAgentsWeb.ConnCase

  test "controller submits and lists the authenticated account's chat events", %{conn: conn} do
    key = "chat-turn-api"
    user = github_user("api-token-" <> key)

    response =
      conn
      |> put_chat_api_token(key)
      |> post(~p"/api/v1/chat/turns", %{"message" => "Read the README."})
      |> json_response(202)

    assert %{"id" => run_id, "status" => "streaming"} = response["turn"]

    response =
      conn
      |> put_chat_api_token(key)
      |> get(~p"/api/v1/chat/events")
      |> json_response(200)

    assert [first | _events] = response["events"]
    assert first["run_id"] == run_id
    assert first["type"] == "user_message"
    assert first["payload"] == %{"content" => "Read the README."}
    assert OpenAgents.Chat.AccountTurns.list_events(user) == response["events"]
  end

  test "chat API rejects a valid token with the wrong scope", %{conn: conn} do
    refusal =
      conn
      |> put_forge_api_token("chat-wrong-scope")
      |> get(~p"/api/v1/chat/events")

    assert assert_api_error(refusal, 401, "unauthenticated")["error"] == "invalid_api_token"
  end

  test "events expose the same ordered tool lifecycle as the browser projection", %{conn: conn} do
    key = "chat-tool-events"
    user = github_user("api-token-" <> key)

    streamer = fn _request, callback, _options ->
      callback.(
        {:tool_call_started,
         %{
           "call_id" => "call-write",
           "name" => "write",
           "arguments" => ~s({"path":"notes.txt","content":"done"})
         }}
      )

      callback.(
        {:tool_call_completed,
         %{
           "call_id" => "call-write",
           "output" => %{
             "schema" => "sarah.tool_outcome.v1",
             "status" => "succeeded",
             "result" => %{"bytes_written" => 4},
             "workspace" => %{
               "type" => "forge_worktree",
               "path" => "/private/var/lib/openagents/workspaces/repo"
             },
             "target_receipt_refs" => ["receipt:write:1"],
             "started_at" => "2026-08-22T19:43:28.000Z",
             "completed_at" => "2026-08-22T19:43:28.010Z"
           }
         }}
      )

      {:ok, %{"assistant_content" => "Wrote the file."}}
    end

    assert {:ok, %{"id" => run_id}} =
             OpenAgents.Chat.AccountTurns.submit(user, "Write the note.",
               subscriber: self(),
               streamer: streamer
             )

    assert_receive {:account_chat_completed, ^run_id, {:ok, _completion}}

    events =
      conn
      |> put_chat_api_token(key)
      |> get(~p"/api/v1/chat/events")
      |> json_response(200)
      |> Map.fetch!("events")

    assert Enum.map(events, & &1["type"]) == [
             "user_message",
             "tool_call_started",
             "tool_call_completed",
             "response_completed"
           ]

    completed = Enum.at(events, 2)["tool_call"]

    [browser_tool] =
      OpenAgents.Chat.AccountTurns.list_messages(user) |> List.last() |> Map.fetch!(:tool_calls)

    assert completed["status"] == browser_tool.status
    assert completed["state"] == browser_tool.state
    assert completed["workspace"] == browser_tool.workspace
    assert completed["duration_ms"] == browser_tool.duration_ms
    assert completed["receipt_refs"] == browser_tool.receipt_refs
    assert completed["output"] == browser_tool.output
    assert completed["workspace"]["path"] == "repo"
    refute inspect(events) =~ "/private/var/lib/openagents"
  end

  test "pull request results retain browser and API lifecycle parity", %{conn: conn} do
    key = "chat-pull-request-events"
    user = github_user("api-token-" <> key)

    result = %{
      "repository" => "OpenAgentsInc/openagents.com",
      "url" => "/OpenAgentsInc/openagents.com/pulls/17",
      "head" => %{
        "ref" => "openagents/chat/8cc3bd8d-08cc-4c94-85e1-f269421ddf14",
        "oid" => String.duplicate("b", 40)
      },
      "checks" => %{"state" => "unknown"}
    }

    streamer = fn _request, callback, _options ->
      callback.(
        {:tool_call_started,
         %{
           "call_id" => "call-open-pr",
           "name" => "open_pull_request",
           "arguments" =>
             ~s({"publication_receipt_ref":"repository-publication:17","title":"Review changes","draft":true})
         }}
      )

      callback.(
        {:tool_call_completed,
         %{
           "call_id" => "call-open-pr",
           "output" => %{
             "schema" => "sarah.tool_outcome.v1",
             "status" => "succeeded",
             "result" => result,
             "target_receipt_refs" => ["repository-publication:17", "pull-request:17"],
             "started_at" => "2026-08-22T19:43:28.000Z",
             "completed_at" => "2026-08-22T19:43:28.010Z"
           }
         }}
      )

      {:ok, %{"assistant_content" => "Opened the draft pull request."}}
    end

    assert {:ok, %{"id" => run_id}} =
             OpenAgents.Chat.AccountTurns.submit(user, "Open a pull request.",
               subscriber: self(),
               streamer: streamer
             )

    assert_receive {:account_chat_completed, ^run_id, {:ok, _completion}}

    events =
      conn
      |> put_chat_api_token(key)
      |> get(~p"/api/v1/chat/events")
      |> json_response(200)
      |> Map.fetch!("events")

    completed =
      Enum.find_value(events, fn
        %{"type" => "tool_call_completed", "tool_call" => tool_call} -> tool_call
        _event -> nil
      end)

    [browser_tool] =
      OpenAgents.Chat.AccountTurns.list_messages(user) |> List.last() |> Map.fetch!(:tool_calls)

    assert completed["name"] == "open_pull_request"
    assert completed["status"] == browser_tool.status
    assert completed["receipt_refs"] == browser_tool.receipt_refs
    assert completed["output"] == browser_tool.output

    decoded_output = Jason.decode!(completed["output"])
    assert decoded_output == result
    assert decoded_output["url"] =~ "/pulls/17"
    assert decoded_output["head"]["oid"] == String.duplicate("b", 40)
  end

  test "chat API requires a bearer token", %{conn: conn} do
    assert conn |> get(~p"/api/v1/chat/events") |> api_error_code(401) == "unauthenticated"
  end

  describe "backend selection" do
    test "a turn names the backend it went to, whether or not it chose one", %{conn: conn} do
      for {sent, expected} <- [
            {%{}, "glm-5.3-flash"},
            {%{"model" => "gemini-3.7-flash"}, "gemini-3.7-flash"}
          ] do
        key = "chat-backend-" <> expected

        response =
          conn
          |> put_chat_api_token(key)
          |> post(~p"/api/v1/chat/turns", Map.merge(%{"message" => "Hello."}, sent))
          |> json_response(202)

        assert response["turn"]["model"] == expected
      end
    end

    test "an unsupported model is a field-level refusal, not the default", %{conn: conn} do
      refusal =
        conn
        |> put_chat_api_token("chat-bad-backend")
        |> post(~p"/api/v1/chat/turns", %{"message" => "Hello.", "model" => "gpt-4"})

      body = json_response(refusal, 422)

      assert body["code"] == "validation_failed"
      assert body["status"] == 422
      assert Map.has_key?(body["errors"], "model")
      assert hd(body["errors"]["model"]) =~ "gemini-3.7-flash"

      # The key published clients already read stays beside the envelope.
      assert body["error"] == "unsupported_model"
    end

    test "an empty model means no preference rather than a bad one", %{conn: conn} do
      response =
        conn
        |> put_chat_api_token("chat-empty-backend")
        |> post(~p"/api/v1/chat/turns", %{"message" => "Hello.", "model" => ""})
        |> json_response(202)

      assert response["turn"]["model"] == "glm-5.3-flash"
    end
  end
end
