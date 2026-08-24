defmodule OpenAgentsWeb.InferenceProxyControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Inference
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Machines
  alias OpenAgents.Providers.RecordingTestProvider
  alias OpenAgents.Repo

  defp grant(key, options \\ []) do
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

    mint_input = %{
      owner_visitor_id: conversation.visitor_id,
      conversation_id: conversation.id,
      machine_id: machine.id
    }

    mint_input =
      case Keyword.fetch(options, :model_id) do
        {:ok, model_id} -> Map.put(mint_input, :model_id, model_id)
        :error -> mint_input
      end

    {:ok, grant, token} = Inference.mint(mint_input)

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
        "model" => OpenAgents.Inference.Models.default_id(),
        "messages" => [
          %{"role" => "system", "content" => "You are helpful."},
          %{"role" => "user", "content" => "hello there"}
        ],
        "stream" => true
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

    # The effective model is attributed on the response itself (PROVIDER-002):
    # the header and every chunk name the model that answered.
    assert get_resp_header(conn, "x-openagents-model") ==
             [OpenAgents.Inference.Models.default_id()]

    events = sse_events(conn.resp_body)
    assert List.last(events) == "[DONE]"

    for chunk <- events, chunk != "[DONE]" do
      assert Jason.decode!(chunk)["model"] == OpenAgents.Inference.Models.default_id()
    end

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

  test "a reasoning stream survives translation as delta.reasoning", %{conn: conn} do
    %{token: token} = grant("reasoning")

    conn =
      post_chat(conn, token, %{
        "messages" => [%{"role" => "user", "content" => "[reasoning]"}]
      })

    assert conn.status == 200

    decoded =
      conn.resp_body
      |> sse_events()
      |> Enum.filter(&(&1 != "[DONE]"))
      |> Enum.map(&Jason.decode!/1)

    reasoning =
      decoded
      |> Enum.flat_map(fn chunk ->
        get_in(chunk, ["choices", Access.at(0), "delta", "reasoning"]) |> List.wrap()
      end)
      |> Enum.join("")

    assert reasoning == "Considering the request. Deciding on a reply."

    # The reply text still arrives, in its own content deltas.
    text =
      decoded
      |> Enum.flat_map(fn chunk ->
        get_in(chunk, ["choices", Access.at(0), "delta", "content"]) |> List.wrap()
      end)
      |> Enum.join("")

    assert text == "Here is the reply."
    assert Enum.any?(decoded, &(get_in(&1, ["choices", Access.at(0), "finish_reason"]) == "stop"))
  end

  test "a provider tool call reaches the caller as a tool_calls delta", %{conn: conn} do
    %{token: token} = grant("tool-out")

    conn =
      post_chat(conn, token, %{
        "messages" => [%{"role" => "user", "content" => "[tool-loop]"}],
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "recall_messages",
              "description" => "Recall messages",
              "parameters" => %{"type" => "object"}
            }
          }
        ]
      })

    assert conn.status == 200

    decoded =
      conn.resp_body
      |> sse_events()
      |> Enum.filter(&(&1 != "[DONE]"))
      |> Enum.map(&Jason.decode!/1)

    [tool_call] =
      Enum.flat_map(decoded, fn chunk ->
        get_in(chunk, ["choices", Access.at(0), "delta", "tool_calls"]) || []
      end)

    assert tool_call["id"] == "call-tool-1"
    assert tool_call["type"] == "function"
    assert tool_call["function"]["name"] == "recall_messages"
    assert Jason.decode!(tool_call["function"]["arguments"]) == %{"query" => "quartz"}

    assert Enum.any?(
             decoded,
             &(get_in(&1, ["choices", Access.at(0), "finish_reason"]) == "tool_calls")
           )
  end

  test "a body naming a model outside the catalog is refused, naming the served set",
       %{conn: conn} do
    %{grant: grant, token: token} = grant("model-not-served")

    conn =
      post_chat(conn, token, %{
        "model" => "attacker/gpt-9-ultra",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })

    # Never a 202-and-answer-from-another-model (#160): the refusal is typed,
    # echoes what was asked, and names what is served.
    assert conn.status == 422
    error = Jason.decode!(conn.resp_body)["error"]
    assert error["code"] == "model_not_served"
    assert error["requested"] == "attacker/gpt-9-ultra"
    assert error["served"] == OpenAgents.Inference.Models.ids()

    # The grant's model_id stays Sarah's configured model, never the body's.
    assert grant.model_id == Application.fetch_env!(:openagents, :openai_model)
  end

  test "a body naming a served model other than the grant's is refused, never substituted",
       %{conn: conn} do
    %{token: token} = grant("model-mismatch")

    conn =
      post_chat(conn, token, %{
        "model" => "ox-alpha",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })

    assert conn.status == 422
    error = Jason.decode!(conn.resp_body)["error"]
    assert error["code"] == "model_mismatch"
    assert error["requested"] == "ox-alpha"
    assert error["granted"] == OpenAgents.Inference.Models.default_id()
    assert error["served"] == OpenAgents.Inference.Models.ids()
  end

  test "the vendor spelling of the grant's model is the same name, not a mismatch",
       %{conn: conn} do
    %{token: token} = grant("model-vendor-spelling", model_id: "ox-alpha")

    conn =
      post_chat(conn, token, %{
        "model" => OpenAgents.Chat.OpenRouter.default_model(),
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert conn.status == 200
    assert get_resp_header(conn, "x-openagents-model") == ["ox-alpha"]
  end

  test "a grant on a lane without a credential is refused before any provider call",
       %{conn: conn} do
    # Minted while the lane was configured; the credential goes away under a
    # live grant. The UnconfiguredTestProvider raises from `stream/2`, so a
    # 503 here also proves no provider was called.
    %{token: token} = grant("model-lane-unavailable", model_id: "ox-alpha")

    previous = Application.get_env(:openagents, :openrouter_provider)

    Application.put_env(
      :openagents,
      :openrouter_provider,
      OpenAgents.Providers.UnconfiguredTestProvider
    )

    on_exit(fn -> Application.put_env(:openagents, :openrouter_provider, previous) end)

    conn = post_chat(conn, token, %{"messages" => [%{"role" => "user", "content" => "hi"}]})

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "model_unavailable"
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

  describe "routing the grant's model" do
    setup do
      previous = Application.get_env(:openagents, :openrouter_provider)
      Application.put_env(:openagents, :openrouter_provider, RecordingTestProvider)
      Application.put_env(:openagents, :test_recording_provider_observer, self())

      on_exit(fn ->
        Application.put_env(:openagents, :openrouter_provider, previous)
        Application.delete_env(:openagents, :test_recording_provider_observer)
      end)
    end

    test "an ox-alpha grant reaches the OpenRouter lane with the vendor model", %{conn: conn} do
      %{token: token} = grant("ox-alpha", model_id: "ox-alpha")

      conn = post_chat(conn, token, %{"messages" => [%{"role" => "user", "content" => "hi"}]})

      assert conn.status == 200
      assert_received {:recorded_request, "test.recording_provider", request}
      assert request.model_id == OpenAgents.Chat.OpenRouter.default_model()
    end

    test "tool declarations, a replayed call, and its output reach the provider intact",
         %{conn: conn} do
      %{token: token} = grant("tool-fidelity", model_id: "ox-alpha")

      conn =
        post_chat(conn, token, %{
          "messages" => [
            %{"role" => "user", "content" => "Read the file."},
            %{
              "role" => "assistant",
              "content" => "",
              "tool_calls" => [
                %{
                  "id" => "call_read",
                  "type" => "function",
                  "function" => %{
                    "name" => "read_file",
                    "arguments" => ~s({"path":"a.txt"})
                  }
                }
              ]
            },
            %{"role" => "tool", "tool_call_id" => "call_read", "content" => "hello"}
          ],
          "tools" => [
            %{
              "type" => "function",
              "function" => %{
                "name" => "read_file",
                "description" => "Read a file",
                "parameters" => %{"type" => "object"}
              }
            }
          ]
        })

      assert conn.status == 200
      assert_received {:recorded_request, "test.recording_provider", request}

      assert [definition] = request.tool_definitions
      assert definition.name == "read_file"
      assert definition.input_schema == %{"type" => "object"}

      # The assistant turn that carried only a tool call is not dropped from
      # the transcript, and its call travels with it.
      assert [
               %{role: "user", content: "Read the file."},
               %{role: "assistant", content: "", tool_calls: [call]}
             ] = request.input

      assert call == %{call_id: "call_read", name: "read_file", arguments: ~s({"path":"a.txt"})}

      assert [output] = request.tool_outputs
      assert output.call_id == "call_read"
      assert output.output == %{"content" => "hello"}
    end

    test "a default grant stays on the default lane", %{conn: conn} do
      %{token: token} = grant("default-lane")

      conn = post_chat(conn, token, %{"messages" => [%{"role" => "user", "content" => "hi"}]})

      assert conn.status == 200
      refute_received {:recorded_request, _id, _request}
    end

    test "a grant naming a model the proxy cannot route is refused", %{conn: conn} do
      %{token: token} = grant("withdrawn")

      # A grant's model column is immutable and the mint refuses an unroutable
      # name, so the only way here is the routed set changing underneath a live
      # grant — a model withdrawn after it was issued.
      configured = Application.fetch_env!(:openagents, :openai_model)
      Application.put_env(:openagents, :openai_model, "#{configured}-withdrawn")
      on_exit(fn -> Application.put_env(:openagents, :openai_model, configured) end)

      conn = post_chat(conn, token, %{"messages" => [%{"role" => "user", "content" => "hi"}]})

      assert conn.status == 503
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "model_unavailable"
    end
  end
end
