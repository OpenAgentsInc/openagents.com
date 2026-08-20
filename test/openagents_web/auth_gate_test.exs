defmodule OpenAgentsWeb.AuthGateTest do
  use OpenAgentsWeb.SarahConnCase, async: true
  import Ecto.Query

  alias OpenAgents.Conversations.{Conversation, Visitor}
  alias OpenAgents.{Accounts, Conversations, Repo}

  test "every Sarah route rejects an unauthenticated request before creating state", %{conn: conn} do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    requests = [
      {:get, ~p"/chat", nil},
      {:get, ~p"/computers", nil},
      {:get, ~p"/machines", nil},
      {:get, ~p"/memory/export", nil},
      {:get, ~p"/data/export", nil},
      {:get, ~p"/data/export/atif", nil},
      {:delete, ~p"/data", %{"privacy" => %{"confirmation" => "DELETE MY SARAH DATA"}}},
      {:post, ~p"/voice/calls", "v=0\r\n"},
      {:post, ~p"/voice/calls/interrupt", ""},
      {:post, ~p"/voice/telemetry", Jason.encode!(%{kind: "peer_connected"})},
      {:delete, ~p"/voice/calls", nil}
    ]

    Enum.each(requests, fn {method, path, body} ->
      response =
        conn
        |> recycle()
        |> init_test_session(%{})
        |> put_req_header("x-csrf-token", csrf_token)
        |> request(method, path, body)

      assert response.status == 302
      assert get_resp_header(response, "location") == ["/"]
    end)

    assert Repo.aggregate(Visitor, :count) == 0
    assert Repo.aggregate(Conversation, :count) == 0
  end

  test "health endpoints remain public and create no identity state", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get(~p"/status") |> json_response(200)
    assert %{"status" => "ok"} = conn |> recycle() |> get(~p"/healthz") |> json_response(200)
    assert Repo.aggregate(from(visitor in Visitor), :count) == 0
  end

  test "legacy browser credentials and banned account sessions cannot authorize Sarah", %{
    conn: conn
  } do
    legacy_key = "pre-authentication-browser-key"
    assert {:ok, legacy_conversation} = Conversations.ensure_conversation(legacy_key)

    legacy_request =
      conn
      |> init_test_session(%{"visitor_token" => legacy_key})
      |> get(~p"/chat")

    assert redirected_to(legacy_request) == ~p"/"
    assert Conversations.get_conversation_for_browser(legacy_key).id == legacy_conversation.id

    user = github_user("banned-http-user")
    assert {:ok, _banned} = Accounts.ban_user(user, "manual_abuse_review")

    banned_request =
      conn
      |> recycle()
      |> init_test_session(%{"user_id" => user.id})
      |> get(~p"/data/export")

    assert redirected_to(banned_request) == ~p"/"
    assert get_session(banned_request, "user_id") == nil
  end

  defp request(conn, :get, path, _body), do: get(conn, path)

  defp request(conn, :post, path, body) when is_binary(body) do
    content_type = if path == "/voice/calls", do: "application/sdp", else: "application/json"

    conn
    |> put_req_header("content-type", content_type)
    |> post(path, body)
  end

  defp request(conn, :delete, path, body), do: delete(conn, path, body)
end
