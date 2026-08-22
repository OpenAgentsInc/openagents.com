defmodule OpenAgentsWeb.ChatResponseControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:openagents, :chat_provider)
    Application.put_env(:openagents, :chat_provider, OpenAgents.ChatProviderStub)

    on_exit(fn ->
      if previous do
        Application.put_env(:openagents, :chat_provider, previous)
      else
        Application.delete_env(:openagents, :chat_provider)
      end
    end)
  end

  test "an account token runs chat with the issuing user's authority", %{conn: conn} do
    user = github_user("account-chat-owner")
    conn = put_account_api_token_for_user(conn, user)

    response = post(conn, ~p"/api/v1/chat/responses", %{input: "Read my repository."})

    assert %{
             "status" => "completed",
             "model" => "test/provider",
             "output_text" => output,
             "events" => events
           } = json_response(response, 200)

    assert output == "#{user.github_login}: Read my repository."

    assert Enum.map(events, & &1["type"]) == [
             "response.reasoning.delta",
             "response.tool_call.started",
             "response.tool_call.completed",
             "response.output_text.delta"
           ]
  end

  test "the streaming response exposes reasoning, tools, text, and completion", %{conn: conn} do
    user = github_user("account-chat-stream-owner")

    response =
      conn
      |> put_account_api_token_for_user(user)
      |> post(~p"/api/v1/chat/responses", %{input: "Stream this.", stream: true})

    body = response.resp_body
    assert body =~ "response.reasoning.delta"
    assert body =~ "response.tool_call.started"
    assert body =~ "response.tool_call.completed"
    assert body =~ "response.output_text.delta"
    assert body =~ "response.completed"
  end

  test "missing and forge-only tokens cannot control an account", %{conn: conn} do
    path = ~p"/api/v1/chat/responses"
    assert conn |> post(path, %{input: "Denied"}) |> json_response(401)

    user = github_user("forge-only-chat-owner")

    {:ok, _credential, plaintext} =
      OpenAgents.ApiTokens.create(user, %{
        name: "forge only",
        scopes: ["forge:write"],
        lifetime_days: 1
      })

    denied =
      conn
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> post(path, %{input: "Denied"})

    assert json_response(denied, 401) == %{"error" => "invalid_api_token"}
  end

  test "revocation immediately removes account authority", %{conn: conn} do
    user = github_user("revoked-account-chat-owner")

    {:ok, credential, plaintext} =
      OpenAgents.ApiTokens.create(user, %{
        name: "revoked account client",
        scopes: ["account:write", "forge:write"]
      })

    assert {:ok, _credential} = OpenAgents.ApiTokens.revoke(user, credential.id)

    denied =
      conn
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> post(~p"/api/v1/chat/responses", %{input: "Denied"})

    assert json_response(denied, 401) == %{"error" => "invalid_api_token"}
  end
end
