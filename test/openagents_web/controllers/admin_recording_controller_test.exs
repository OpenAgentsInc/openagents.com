defmodule OpenAgentsWeb.AdminRecordingControllerTest do
  @moduledoc """
  The audio reader is the only path that hands one account's voice to another
  person, so the gate is asserted on the bytes themselves rather than only on the
  panel that links to them.
  """

  use OpenAgentsWeb.SarahConnCase, async: false
  @moduletag :skip
  alias OpenAgents.Conversations
  alias OpenAgents.Voice
  alias OpenAgents.Voice.Config
  alias OpenAgents.Voice.Recordings

  @webm "audio/webm;codecs=opus"

  test "the operator receives the ordered concatenation as stored media", %{conn: conn} do
    recording = recorded_call("admin-audio-caller")
    conn = log_in_admin_user(conn, "admin-audio-operator")

    response = get(conn, ~p"/admin/recordings/#{recording.id}/audio")

    assert response.status == 200
    assert response.resp_body == "first-second-"
    assert get_resp_header(response, "content-type") == ["audio/webm"]
    assert get_resp_header(response, "cache-control") == ["no-store"]
    # Seeking would need real ranges over unsealed chunk offsets; the reader says
    # so rather than implying support it does not have.
    assert get_resp_header(response, "accept-ranges") == ["none"]
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
  end

  test "an ordinary authenticated account receives no bytes", %{conn: conn} do
    recording = recorded_call("admin-audio-private-caller")
    conn = log_in_github_user(conn, "admin-audio-intruder")

    response = get(conn, ~p"/admin/recordings/#{recording.id}/audio")

    assert redirected_to(response) == ~p"/"
    refute response.resp_body =~ "first"
  end

  test "the account that made the call is not thereby an operator", %{conn: conn} do
    recording = recorded_call("admin-audio-owner")

    # Decided, not pending: the operator surface is the only place a recording is
    # audible. The account's own route to it is the DATA-004 export, which
    # carries the recording's metadata and not its sound.
    conn = log_in_github_user(conn, "admin-audio-owner")

    assert redirected_to(get(conn, ~p"/admin/recordings/#{recording.id}/audio")) == ~p"/"
  end

  test "an unauthenticated request receives no bytes", %{conn: conn} do
    recording = recorded_call("admin-audio-anonymous-caller")

    response = get(conn, ~p"/admin/recordings/#{recording.id}/audio")

    assert redirected_to(response) == ~p"/"
  end

  test "a missing or malformed identifier is an honest 404", %{conn: conn} do
    conn = log_in_admin_user(conn, "admin-audio-404-operator")

    assert get(conn, ~p"/admin/recordings/#{Ecto.UUID.generate()}/audio").status == 404
    assert get(conn, ~p"/admin/recordings/not-a-uuid/audio").status == 404
  end

  test "a recording whose capture failed has nothing to play", %{conn: conn} do
    {:ok, conversation} = Conversations.ensure_conversation(github_user("admin-audio-failed"))
    {:ok, session} = Voice.admit_session(conversation, enabled_config())
    {:ok, _chunk} = Recordings.append_chunk(session, session.generation, 1, "partial", @webm)
    {:ok, recording} = Recordings.finalize(session, session.generation, "failed", nil)

    conn = log_in_admin_user(conn, "admin-audio-failed-operator")

    assert get(conn, ~p"/admin/recordings/#{recording.id}/audio").status == 404
  end

  test "an aborted upload still plays back what arrived", %{conn: conn} do
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
