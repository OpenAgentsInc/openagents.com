defmodule OpenAgentsWeb.VoiceTelemetryControllerTest do
  use OpenAgentsWeb.SarahConnCase, async: false
  @moduletag :skip
  import Ecto.Query

  alias OpenAgents.{Conversations, Repo, Voice}
  alias OpenAgents.Voice.ClientEvent

  setup do
    previous_voice = Application.fetch_env!(:openagents, :voice)
    Application.put_env(:openagents, :voice, Keyword.put(previous_voice, :enabled, true))
    on_exit(fn -> Application.put_env(:openagents, :voice, previous_voice) end)
    :ok
  end

  test "accepts only a bounded event name and server-derived browser family", %{conn: conn} do
    token = "voice-telemetry-browser-credential-000000000000"
    {:ok, conversation} = Conversations.ensure_conversation(github_user(token))
    {:ok, session} = Voice.admit_session(conversation, Voice.Config.current!())

    conn = post_event(conn, token, "peer_connected")
    assert response(conn, 204) == ""

    assert [event] =
             Repo.all(from(event in ClientEvent, where: event.voice_session_id == ^session.id))

    assert event.kind == "peer_connected"
    assert event.browser_family == "chrome"
    assert event.browser_major == 141

    invalid = conn |> recycle() |> post_event(token, "raw_audio")
    assert response(invalid, 400) == ""
  end

  test "missing or terminal sessions do not disclose state", %{conn: conn} do
    conn = post_event(conn, "no-active-voice-browser-credential-0000000000", "client_failed")
    assert response(conn, 204) == ""
  end

  defp post_event(conn, token, kind) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> log_in_github_user(token)
    |> put_req_header("accept", "text/html")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("user-agent", "Mozilla/5.0 Chrome/141.0.0.0 Safari/537.36")
    |> put_req_header("x-csrf-token", csrf_token)
    |> post(~p"/voice/telemetry", Jason.encode!(%{kind: kind}))
  end
end
