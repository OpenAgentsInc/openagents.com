defmodule OpenAgentsWeb.VoiceRecordingControllerTest do
  @moduledoc """
  The upload endpoint is the one place a browser hands Sarah raw bytes, so these
  cover what it must refuse: an unauthenticated caller, an oversized body, a
  container outside the allowlist, and another account's call.
  """

  use OpenAgentsWeb.ConnCase, async: false
  alias OpenAgents.Conversations
  alias OpenAgents.Voice
  alias OpenAgents.Voice.Config
  alias OpenAgents.Voice.Recordings

  @webm "audio/webm;codecs=opus"

  setup do
    original = Application.get_env(:openagents, :voice)

    Application.put_env(
      :openagents,
      :voice,
      Keyword.merge(original, enabled: true)
    )

    on_exit(fn -> Application.put_env(:openagents, :voice, original) end)
    :ok
  end

  test "commits a slice for the caller's own call", %{conn: conn} do
    conn = log_in_github_user(conn, "recording-upload-user")
    session = admitted_session(conn)

    response =
      conn
      |> chunk_headers(session.generation, 1)
      |> post(~p"/voice/calls/recording", "opus-bytes")

    assert response.status == 204

    recording = Recordings.for_session(session)
    assert recording.chunk_count == 1
    assert recording.byte_size == byte_size("opus-bytes")
  end

  test "refuses an unauthenticated upload without touching the database", %{conn: conn} do
    response =
      conn
      |> chunk_headers(1, 1)
      |> post(~p"/voice/calls/recording", "opus-bytes")

    assert redirected_to(response) == ~p"/"
    assert OpenAgents.Repo.aggregate(OpenAgents.Voice.Recording, :count) == 0
  end

  test "refuses a body past the chunk ceiling", %{conn: conn} do
    conn = log_in_github_user(conn, "recording-oversized-user")
    session = admitted_session(conn)
    oversized = :binary.copy("a", Recordings.config().maximum_chunk_bytes + 1)

    response =
      conn
      |> chunk_headers(session.generation, 1)
      |> post(~p"/voice/calls/recording", oversized)

    assert response.status == 413
    assert json_response(response, 413) == %{"error" => "voice_recording_chunk_too_large"}
    refute Recordings.for_session(session)
  end

  test "refuses a container outside the stored allowlist", %{conn: conn} do
    conn = log_in_github_user(conn, "recording-container-user")
    session = admitted_session(conn)

    response =
      conn
      |> put_req_header("content-type", "audio/wav")
      |> put_req_header("x-voice-generation", to_string(session.generation))
      |> put_req_header("x-voice-recording-sequence", "1")
      |> post(~p"/voice/calls/recording", "riff-bytes")

    assert response.status == 415
    refute Recordings.for_session(session)
  end

  test "refuses a malformed generation or sequence header", %{conn: conn} do
    conn = log_in_github_user(conn, "recording-headers-user")
    session = admitted_session(conn)

    for {generation, sequence} <- [{"0", "1"}, {"1", "0"}, {"abc", "1"}, {"1", "-2"}] do
      response =
        conn
        |> put_req_header("content-type", @webm)
        |> put_req_header("x-voice-generation", generation)
        |> put_req_header("x-voice-recording-sequence", sequence)
        |> post(~p"/voice/calls/recording", "opus-bytes")

      assert response.status == 400
    end

    refute Recordings.for_session(session)
  end

  test "one account cannot upload into another account's call", %{conn: conn} do
    owner_conn = log_in_github_user(conn, "recording-owner-user")
    session = admitted_session(owner_conn)

    # The session is resolved from the session cookie, never from a client
    # identifier, so the intruder's own (absent) call is what is looked up.
    intruder = log_in_github_user(Phoenix.ConnTest.build_conn(), "recording-intruder-user")

    response =
      intruder
      |> chunk_headers(session.generation, 1)
      |> post(~p"/voice/calls/recording", "opus-bytes")

    assert response.status == 409
    refute Recordings.for_session(session)
  end

  test "an empty body is a client error, not an empty slice", %{conn: conn} do
    conn = log_in_github_user(conn, "recording-empty-user")
    session = admitted_session(conn)

    response =
      conn
      |> chunk_headers(session.generation, 1)
      |> post(~p"/voice/calls/recording", "")

    assert response.status == 400
    refute Recordings.for_session(session)
  end

  test "completing closes the recording after the call has already ended", %{conn: conn} do
    conn = log_in_github_user(conn, "recording-complete-user")
    session = admitted_session(conn)

    assert conn
           |> chunk_headers(session.generation, 1)
           |> post(~p"/voice/calls/recording", "opus-bytes")
           |> Map.fetch!(:status) == 204

    {:ok, _ended} = Voice.end_session(session, session.generation, "user_ended")

    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-voice-generation", to_string(session.generation))
      |> post(~p"/voice/calls/recording/complete", %{
        "status" => "complete",
        "duration_ms" => 4_200
      })

    assert response.status == 204

    recording = Recordings.for_session(session)
    assert recording.status == "complete"
    assert recording.client_duration_ms == 4_200
  end

  test "completing a call that uploaded nothing is a no-op", %{conn: conn} do
    conn = log_in_github_user(conn, "recording-nothing-user")
    session = admitted_session(conn)

    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-voice-generation", to_string(session.generation))
      |> post(~p"/voice/calls/recording/complete", %{"status" => "complete"})

    assert response.status == 204
    refute Recordings.for_session(session)
  end

  test "recording off refuses uploads while leaving the call alone", %{conn: conn} do
    conn = log_in_github_user(conn, "recording-disabled-user")
    session = admitted_session(conn)
    original = Application.get_env(:openagents, :voice_recording)

    try do
      Application.put_env(:openagents, :voice_recording, Keyword.merge(original, enabled: false))

      response =
        conn
        |> chunk_headers(session.generation, 1)
        |> post(~p"/voice/calls/recording", "opus-bytes")

      assert response.status == 503
      assert json_response(response, 503) == %{"error" => "voice_recording_disabled"}
    after
      Application.put_env(:openagents, :voice_recording, original)
    end

    # The call itself is untouched: an unrecorded conversation, not a failed one.
    assert Voice.get_session!(session.id).status == "connecting"
  end

  defp chunk_headers(conn, generation, sequence) do
    conn
    |> put_req_header("content-type", @webm)
    |> put_req_header("x-voice-generation", to_string(generation))
    |> put_req_header("x-voice-recording-sequence", to_string(sequence))
  end

  defp admitted_session(conn) do
    user = conn.private[:plug_session]["user_id"] |> OpenAgents.Accounts.get_user()
    {:ok, conversation} = Conversations.ensure_conversation(user)
    {:ok, session} = Voice.admit_session(conversation, enabled_config())
    session
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
