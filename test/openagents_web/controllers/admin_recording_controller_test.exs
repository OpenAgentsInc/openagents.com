defmodule OpenAgentsWeb.AdminRecordingControllerTest do
  @moduledoc """
  The recording reader is the only route that gives one account's voice to
  another person, so these tests enforce authorization on the media bytes.
  """

  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Conversations
  alias OpenAgents.Voice
  alias OpenAgents.Voice.Config
  alias OpenAgents.Voice.Recordings

  @webm "audio/webm;codecs=opus"

  test "the operator receives ordered recording media", %{conn: conn} do
    recording = recorded_call("admin-audio-caller")
    conn = log_in_admin_user(conn, "admin-audio-operator")

    response = get(conn, ~p"/admin/recordings/#{recording.id}/audio")

    assert response.status == 200
    assert response.resp_body == "first-second-"
    assert get_resp_header(response, "content-type") == ["audio/webm"]
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "accept-ranges") == ["none"]
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
  end

  test "ordinary, owning, and anonymous accounts receive no media bytes", %{conn: conn} do
    recording = recorded_call("admin-audio-private-caller")

    ordinary = log_in_github_user(conn, "admin-audio-intruder")
    assert redirected_to(get(ordinary, ~p"/admin/recordings/#{recording.id}/audio")) == ~p"/"

    owner = log_in_github_user(Phoenix.ConnTest.build_conn(), "admin-audio-private-caller")
    assert redirected_to(get(owner, ~p"/admin/recordings/#{recording.id}/audio")) == ~p"/"

    anonymous = get(Phoenix.ConnTest.build_conn(), ~p"/admin/recordings/#{recording.id}/audio")
    assert redirected_to(anonymous) == ~p"/"
  end

  test "missing, malformed, and failed recordings return 404", %{conn: conn} do
    conn = log_in_admin_user(conn, "admin-audio-404-operator")

    assert get(conn, ~p"/admin/recordings/#{Ecto.UUID.generate()}/audio").status == 404
    assert get(conn, ~p"/admin/recordings/not-a-uuid/audio").status == 404

    {:ok, conversation} = Conversations.ensure_conversation(github_user("admin-audio-failed"))
    {:ok, session} = Voice.admit_session(conversation, enabled_config())
    {:ok, _chunk} = Recordings.append_chunk(session, session.generation, 1, "partial", @webm)
    {:ok, recording} = Recordings.finalize(session, session.generation, "failed", nil)

    assert get(conn, ~p"/admin/recordings/#{recording.id}/audio").status == 404
  end

  test "an aborted upload plays the bytes that arrived", %{conn: conn} do
    {:ok, conversation} = Conversations.ensure_conversation(github_user("admin-audio-aborted"))
    {:ok, session} = Voice.admit_session(conversation, enabled_config())
    {:ok, _chunk} = Recordings.append_chunk(session, session.generation, 1, "half-a-call", @webm)
    {:ok, ended} = Voice.end_session(session, session.generation, "client_disconnected")

    grace = Recordings.config().late_chunk_grace_seconds

    ended
    |> Ecto.Changeset.change(%{ended_at: DateTime.add(DateTime.utc_now(), -grace - 5, :second)})
    |> OpenAgents.Repo.update!()

    {:ok, 1} = Recordings.abort_stale()
    recording = Recordings.for_session(session)
    conn = log_in_admin_user(conn, "admin-audio-aborted-operator")

    response = get(conn, ~p"/admin/recordings/#{recording.id}/audio")
    assert response.status == 200
    assert response.resp_body == "half-a-call"
  end

  defp recorded_call(key) do
    {:ok, conversation} = Conversations.ensure_conversation(github_user(key))
    {:ok, session} = Voice.admit_session(conversation, enabled_config())
    {:ok, _first} = Recordings.append_chunk(session, session.generation, 1, "first-", @webm)
    {:ok, _second} = Recordings.append_chunk(session, session.generation, 2, "second-", @webm)
    {:ok, recording} = Recordings.finalize(session, session.generation, "complete", 2_000)
    recording
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
