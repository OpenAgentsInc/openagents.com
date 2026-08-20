defmodule OpenAgentsWeb.InferenceProxyControllerTest do
  use OpenAgentsWeb.SarahConnCase, async: false
  alias OpenAgents.Inference
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Machines
  alias OpenAgents.Repo

  defp grant(key) do
    owner = github_user("proxy-#{key}")
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(owner)

    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => "proxy-box-#{key}",
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => ["/home/x/code"]
      })

    {:ok, machine} = Machines.approve_pairing(owner, code)

    {:ok, grant, token} =
      Inference.mint(%{
        owner_visitor_id: conversation.visitor_id,
        conversation_id: conversation.id,
        machine_id: machine.id
      })

    %{grant: grant, token: token}
  end

  defp post_chat(conn, token, body) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/inference/proxy", Jason.encode!(body))
  end

  defp sse_events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
  end

  test "a valid grant proxies a chat completion and meters usage", %{conn: conn} do
    %{grant: grant, token: token} = grant("ok")

    conn =
      post_chat(conn, token, %{
        "model" => "ignored-by-proxy",
        "messages" => [
          %{"role" => "system", "content" => "You are helpful."},
          %{"role" => "user", "content" => "hello there"}
        ],
        "stream" => true
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

    events = sse_events(conn.resp_body)
    assert List.last(events) == "[DONE]"

    # The Test provider's default path streams "I hear you. You said: <prompt>".
    text =
      events
      |> Enum.filter(&(&1 != "[DONE]"))
      |> Enum.map(&Jason.decode!/1)
      |> Enum.flat_map(fn chunk ->
        get_in(chunk, ["choices", Access.at(0), "delta", "content"]) |> List.wrap()
      end)
      |> Enum.join("")

    assert text =~ "hello there"

    # A finish chunk and a usage chunk are present (probe's parser needs both).
    decoded = events |> Enum.filter(&(&1 != "[DONE]")) |> Enum.map(&Jason.decode!/1)
    assert Enum.any?(decoded, &(get_in(&1, ["choices", Access.at(0), "finish_reason"]) == "stop"))
    usage_chunk = Enum.find(decoded, &Map.has_key?(&1, "usage"))
    assert usage_chunk["usage"]["total_tokens"] == 12

    # Usage was metered against the grant (Test provider emits 4 in / 8 out).
    metered = Repo.get(Grant, grant.id)
    assert metered.call_count == 1
    assert metered.usage["total_tokens"] == 12
    assert metered.usage["estimated_cost_microusd"] > 0
  end

  test "the model is pinned by the grant, not the request body", %{conn: conn} do
    %{grant: grant, token: token} = grant("model-pin")

    _conn =
      post_chat(conn, token, %{
        "model" => "attacker/gpt-9-ultra",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })

    # The grant's model_id is Sarah's configured model, never the body's.
    assert grant.model_id == Application.fetch_env!(:openagents, :openai_model)
  end

  test "missing bearer is rejected", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/inference/proxy", Jason.encode!(%{"messages" => []}))

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "missing_grant"
  end

  test "an unknown grant is rejected", %{conn: conn} do
    conn =
      post_chat(conn, "sig_not_a_real_grant", %{
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_grant"
  end

  test "a revoked grant is refused", %{conn: conn} do
    %{grant: grant, token: token} = grant("revoked")
    {:ok, _} = Inference.revoke(grant)
    conn = post_chat(conn, token, %{"messages" => [%{"role" => "user", "content" => "hi"}]})
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "grant_revoked"
  end

  test "a provider failure surfaces as a bounded error, never raw detail", %{conn: conn} do
    %{token: token} = grant("fail")
    conn = post_chat(conn, token, %{"messages" => [%{"role" => "user", "content" => "[fail]"}]})
    assert conn.status == 502
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "provider_failed"
    # No raw provider detail leaks.
    refute conn.resp_body =~ "test_failure"
  end

  test "an empty message set is refused", %{conn: conn} do
    %{token: token} = grant("empty")
    conn = post_chat(conn, token, %{"messages" => []})
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "empty_input"
  end
end
