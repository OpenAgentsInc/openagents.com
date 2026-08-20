defmodule OpenAgentsWeb.AdminRecordingsLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Conversations
  alias OpenAgents.Voice
  alias OpenAgents.Voice.Config
  alias OpenAgents.Voice.Recordings

  @webm "audio/webm;codecs=opus"

  test "only an operator can open the recording inventory", %{conn: conn} do
    ordinary = log_in_github_user(conn, "recordings-ordinary")
    assert {:error, {:redirect, %{to: "/"}}} = live(ordinary, ~p"/admin/recordings")

    operator = log_in_admin_user(Phoenix.ConnTest.build_conn(), "recordings-operator")
    assert {:ok, view, _html} = live(operator, ~p"/admin/recordings")
    assert has_element?(view, "#admin-recordings-page")
  end

  test "a playable recording renders an operator-only audio source", %{conn: conn} do
    caller = github_user("recordings-caller")
    {:ok, conversation} = Conversations.ensure_conversation(caller)
    {:ok, session} = Voice.admit_session(conversation, enabled_config())

    {:ok, _chunk} =
      Recordings.append_chunk(
        session,
        session.generation,
        1,
        "private-voice-bytes-sentinel",
        @webm
      )

    {:ok, recording} = Recordings.finalize(session, session.generation, "complete", 1_000)

    conn = log_in_admin_user(conn, "recordings-listener")
    {:ok, view, html} = live(conn, ~p"/admin/recordings")

    assert has_element?(view, "#admin-call-#{session.id}")
    assert has_element?(view, ~s(audio[src="/admin/recordings/#{recording.id}/audio"]))
    assert has_element?(view, "#admin-audio-#{session.id}[aria-label]")
    refute html =~ "private-voice-bytes-sentinel"
  end

  defp enabled_config do
    Config.build!(
      enabled: true,
      architecture: :openai_realtime,
      provider: "openai",
      model: "gpt-realtime-2.1",
      voice: "marin",
      reasoning_effort: "low",
      maximum_session_seconds: 3_000
    )
  end
end
