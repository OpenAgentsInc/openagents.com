defmodule OpenAgentsWeb.VoiceCallControllerTest do
  use OpenAgentsWeb.SarahConnCase, async: false
  @moduletag :skip
  setup do
    previous_voice = Application.fetch_env!(:openagents, :voice)
    previous_provider = Application.fetch_env!(:openagents, :voice_call_provider)

    Application.put_env(:openagents, :voice, enabled_voice())
    Application.put_env(:openagents, :voice_call_provider, OpenAgents.Voice.TestCallProvider)
    Application.put_env(:openagents, :voice_call_test_observer, self())
    Application.put_env(:openagents, :voice_sideband_test_observer, self())

    on_exit(fn ->
      Application.put_env(:openagents, :voice, previous_voice)
      Application.put_env(:openagents, :voice_call_provider, previous_provider)
      Application.delete_env(:openagents, :voice_call_test_observer)
      Application.delete_env(:openagents, :voice_sideband_test_observer)
      Application.delete_env(:openagents, :voice_call_test_result)
    end)

    :ok
  end

  test "admits an account-scoped SDP offer without exposing provider credentials", %{conn: conn} do
    conn = post_sdp(conn, "v=0\r\no=browser-offer")

    assert response(conn, 201) == "v=0\r\no=test-answer"
    assert get_resp_header(conn, "content-type") == ["application/sdp; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "permissions-policy") == ["microphone=(self)"]

    assert_receive {:voice_call, "v=0\r\no=browser-offer", safety_identifier, config}
    assert_receive {:sideband_started, _sideband, session}
    assert byte_size(safety_identifier) == 64
    assert config.voice == "marin"
    refute inspect(conn.resp_headers) =~ "OPENAI_API_KEY"
    assert {:ok, _ended} = OpenAgents.VoiceSessions.end_session(session)
  end

  test "fails closed when voice is disabled", %{conn: conn} do
    Application.put_env(:openagents, :voice, Keyword.put(enabled_voice(), :enabled, false))

    conn = post_sdp(conn, "v=0\r\no=browser-offer")

    assert json_response(conn, 503) == %{"error" => "voice_unavailable"}
    refute_received {:voice_call, _sdp, _identifier, _config}
  end

  test "ends only the active session resolved from account identity", %{conn: conn} do
    conn = post_sdp(conn, "v=0\r\no=browser-offer")
    assert response(conn, 201)
    assert_receive {:sideband_started, _sideband, session}

    conn = delete_call(recycle(conn))

    assert response(conn, 204) == ""
    assert OpenAgents.Voice.get_session!(session.id).status == "ended"
    assert OpenAgents.VoiceSessions.whereis(session.id) == nil
  end

  test "ending without an active session is idempotent", %{conn: conn} do
    conn = conn |> log_in_github_user("voice-idempotent-user") |> delete_call()

    assert response(conn, 204) == ""
  end

  test "interrupts only a responding session for the current account", %{conn: conn} do
    conn = post_sdp(conn, "v=0\r\no=browser-offer")
    assert response(conn, 201)
    assert_receive {:sideband_started, _sideband, session}

    assert {:ok, responding, _event, :created} =
             OpenAgents.Voice.record_provider_event(
               session,
               session.generation,
               %OpenAgents.Voice.ProviderEvent{
                 kind: :response_started,
                 provider_event_id: "evt-controller-response",
                 payload: %{"response_id" => "response-controller"}
               }
             )

    conn = post_interrupt(recycle(conn))

    assert response(conn, 204) == ""
    assert_receive {:sideband_event_sent, %{"type" => "response.cancel"}}
    assert OpenAgents.Voice.get_session!(responding.id).status == "interrupted"
    assert {:ok, _ended} = OpenAgents.VoiceSessions.end_session(responding)
  end

  test "refuses voice admission while a text turn is active", %{conn: conn} do
    token = "voice-text-conflict-browser-credential-000000000000"
    user = github_user(token)
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(user)
    {:ok, records} = OpenAgents.Conversations.create_turn(conversation, "A text turn is active")

    conn =
      conn
      |> post_sdp("v=0\r\no=browser-offer", token)

    assert json_response(conn, 409) == %{"error" => "text_turn_in_progress"}
    refute_received {:voice_call, _sdp, _identifier, _config}
    assert {:ok, _failed} = OpenAgents.Conversations.fail_turn(records.turn, :test_cleanup)
  end

  test "rejects malformed SDP before calling the provider", %{conn: conn} do
    conn = post_sdp(conn, "not-sdp")

    assert json_response(conn, 400) == %{"error" => "invalid_sdp"}
    refute_received {:voice_call, _sdp, _identifier, _config}
  end

  defp post_sdp(conn, sdp, key \\ "voice-controller-user") do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> log_in_github_user(key)
    |> put_req_header("accept", "text/html")
    |> put_req_header("content-type", "application/sdp")
    |> put_req_header("x-csrf-token", csrf_token)
    |> post(~p"/voice/calls", sdp)
  end

  defp delete_call(conn) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> put_req_header("accept", "text/html")
    |> put_req_header("x-csrf-token", csrf_token)
    |> delete(~p"/voice/calls")
  end

  defp post_interrupt(conn) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> put_req_header("accept", "text/html")
    |> put_req_header("x-csrf-token", csrf_token)
    |> post(~p"/voice/calls/interrupt")
  end

  defp enabled_voice do
    [
      enabled: true,
      architecture: :openai_realtime,
      provider: "openai",
      model: "gpt-realtime-2.1",
      voice: "marin",
      reasoning_effort: "low",
      maximum_session_seconds: 3_000
    ]
  end
end
