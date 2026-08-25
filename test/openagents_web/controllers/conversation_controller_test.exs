defmodule OpenAgentsWeb.ConversationControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.{ApiTokens, Conversations}

  test "GET /api/v1/conversation names the account's conversation", %{conn: conn} do
    user = github_user("conversation-read")
    {:ok, conversation} = Conversations.ensure_conversation(user)

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> box_control_token(user))
      |> get(~p"/api/v1/conversation")
      |> json_response(200)

    assert response["conversation_id"] == conversation.id
    assert response["conversation"]["id"] == conversation.id
    assert response["conversation"]["created_at"] != nil
  end

  test "GET /api/v1/conversation creates the conversation when the account has none", %{
    conn: conn
  } do
    user = github_user("conversation-bootstrap")
    assert Conversations.get_conversation_for_user(user) == nil

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> box_control_token(user))
      |> get(~p"/api/v1/conversation")
      |> json_response(200)

    assert response["conversation_id"] == Conversations.get_conversation_for_user(user).id
  end

  test "GET /api/v1/conversation is idempotent", %{conn: conn} do
    user = github_user("conversation-idempotent")
    token = box_control_token(user)

    first =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/v1/conversation")
      |> json_response(200)

    second =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/v1/conversation")
      |> json_response(200)

    assert first["conversation_id"] == second["conversation_id"]
  end

  test "GET /api/v1/conversation refuses a token without box:control", %{conn: conn} do
    user = github_user("conversation-wrong-scope")

    {:ok, _token, plaintext} =
      ApiTokens.create(user, %{name: "forge only", scopes: ["forge:write"]})

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> get(~p"/api/v1/conversation")
      |> json_response(401)

    assert response["error"]["code"] == "invalid_api_token"
    assert Conversations.get_conversation_for_user(user) == nil
  end

  test "GET /api/v1/conversation refuses an unauthenticated request", %{conn: conn} do
    assert conn |> get(~p"/api/v1/conversation") |> json_response(401)
  end

  defp box_control_token(user) do
    {:ok, _token, plaintext} =
      ApiTokens.create(user, %{name: "box control", scopes: ["box:control"]})

    plaintext
  end
end
