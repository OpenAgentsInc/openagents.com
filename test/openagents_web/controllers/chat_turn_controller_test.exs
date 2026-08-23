defmodule OpenAgentsWeb.ChatTurnControllerTest do
  use OpenAgentsWeb.ConnCase

  test "controller submits and lists the authenticated account's chat events", %{conn: conn} do
    key = "chat-turn-api"
    user = github_user("api-token-" <> key)

    response =
      conn
      |> put_chat_api_token(key)
      |> post(~p"/api/v3/chat/turns", %{"message" => "Read the README."})
      |> json_response(202)

    assert %{"id" => run_id, "status" => "streaming"} = response["turn"]

    response =
      conn
      |> put_chat_api_token(key)
      |> get(~p"/api/v3/chat/events")
      |> json_response(200)

    assert [first | _events] = response["events"]
    assert first["run_id"] == run_id
    assert first["type"] == "user_message"
    assert first["payload"] == %{"content" => "Read the README."}
    assert OpenAgents.Chat.AccountTurns.list_events(user) == response["events"]
  end

  test "chat API rejects a valid token with the wrong scope", %{conn: conn} do
    assert conn
           |> put_forge_api_token("chat-wrong-scope")
           |> get(~p"/api/v3/chat/events")
           |> json_response(401) == %{"error" => "invalid_api_token"}
  end

  test "chat API requires a bearer token", %{conn: conn} do
    assert conn |> get(~p"/api/v3/chat/events") |> json_response(401) == %{
             "error" => "invalid_api_token"
           }
  end
end
