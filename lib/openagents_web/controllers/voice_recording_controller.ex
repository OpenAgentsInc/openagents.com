defmodule OpenAgentsWeb.VoiceRecordingController do
  @moduledoc """
  Accepts the browser's slices of call audio.

  Deliberately shaped like `OpenAgentsWeb.VoiceTelemetryController`: the session is
  resolved from the encrypted session cookie and the caller's own conversation,
  never from a client-supplied identifier, and a refusal is a bounded code rather
  than provider or database prose.

  A failure here must never take a call down. The browser treats every non-2xx
  as "stop recording, keep talking", which is why the responses are terse and why
  a disabled recorder answers with the same shape as a full one.
  """

  use OpenAgentsWeb, :controller

  import Plug.Conn

  alias OpenAgents.Conversations
  alias OpenAgents.Voice
  alias OpenAgents.Voice.Config
  alias OpenAgents.Voice.Recordings

  def create(conn, _params) do
    settings = Recordings.config()

    with %Config{enabled?: true} <- Config.current!(),
         :ok <- require_recording_enabled(settings),
         {:ok, generation} <- header_integer(conn, "x-voice-generation"),
         {:ok, sequence} <- header_integer(conn, "x-voice-recording-sequence"),
         {:ok, content_type} <- media_type(conn),
         {:ok, session} <- active_session(conn),
         {:ok, chunk, conn} <- read_chunk(conn, settings.maximum_chunk_bytes),
         {:ok, _recording} <-
           Recordings.append_chunk(session, generation, sequence, chunk, content_type) do
      send_resp(conn, :no_content, "")
    else
      %Config{enabled?: false} -> recording_error(conn, :service_unavailable, "voice_unavailable")
      {:error, reason} -> recording_error(conn, status_for(reason), code_for(reason))
      _unavailable -> recording_error(conn, :service_unavailable, "voice_recording_unavailable")
    end
  end

  def complete(conn, params) do
    with %Config{enabled?: true} <- Config.current!(),
         {:ok, generation} <- header_integer(conn, "x-voice-generation"),
         {:ok, status} <- recording_status(params),
         {:ok, session} <- active_session(conn),
         {:ok, _recording} <-
           Recordings.finalize(session, generation, status, duration_ms(params)) do
      send_resp(conn, :no_content, "")
    else
      # Nothing to close is not a client error: the browser finalizes on every
      # exit path, including ones where no audio was ever uploaded.
      {:error, :voice_recording_not_found} -> send_resp(conn, :no_content, "")
      %Config{enabled?: false} -> recording_error(conn, :service_unavailable, "voice_unavailable")
      {:error, reason} -> recording_error(conn, status_for(reason), code_for(reason))
      _unavailable -> recording_error(conn, :service_unavailable, "voice_recording_unavailable")
    end
  end

  defp require_recording_enabled(%{enabled?: true}), do: :ok
  defp require_recording_enabled(%{enabled?: false}), do: {:error, :voice_recording_disabled}

  # The session is the caller's own most recent one rather than the active one:
  # the last slice and the finalize both arrive after the call has ended.
  defp active_session(conn) do
    with %{status: "active"} = user <- conn.assigns.current_user,
         conversation when not is_nil(conversation) <-
           Conversations.get_conversation_for_user(user),
         session when not is_nil(session) <- Voice.latest_session(conversation) do
      {:ok, session}
    else
      _missing -> {:error, :voice_session_not_found}
    end
  end

  defp read_chunk(conn, maximum_bytes) do
    case read_body(conn, length: maximum_bytes, read_length: 65_536) do
      {:ok, body, next_conn} when byte_size(body) > 0 -> {:ok, body, next_conn}
      {:ok, _empty, _next_conn} -> {:error, :invalid_recording_chunk}
      {:more, _partial, _next_conn} -> {:error, :voice_recording_chunk_too_large}
      {:error, _reason} -> {:error, :invalid_recording_chunk}
    end
  end

  defp media_type(conn) do
    case get_req_header(conn, "content-type") do
      [content_type] -> {:ok, content_type}
      _missing_or_repeated -> {:error, :unsupported_recording_media_type}
    end
  end

  defp header_integer(conn, name) do
    with [value] <- get_req_header(conn, name),
         true <- Regex.match?(~r/\A[1-9][0-9]{0,8}\z/, value) do
      {:ok, String.to_integer(value)}
    else
      _invalid -> {:error, :invalid_recording_chunk}
    end
  end

  defp recording_status(%{"status" => status}) when status in ~w(complete failed),
    do: {:ok, status}

  defp recording_status(_params), do: {:ok, "complete"}

  defp duration_ms(%{"duration_ms" => duration}) when is_integer(duration) and duration >= 0,
    do: min(duration, 24 * 60 * 60 * 1_000)

  defp duration_ms(_params), do: nil

  defp status_for(:voice_recording_chunk_too_large), do: :request_entity_too_large
  defp status_for(:voice_recording_limit_reached), do: :request_entity_too_large
  defp status_for(:unsupported_recording_media_type), do: :unsupported_media_type
  defp status_for(:voice_recording_disabled), do: :service_unavailable
  defp status_for(:voice_recording_unavailable), do: :service_unavailable
  defp status_for(:voice_session_not_found), do: :conflict
  defp status_for(:stale_voice_generation), do: :conflict
  defp status_for(:voice_recording_closed), do: :conflict
  defp status_for(:voice_recording_window_closed), do: :conflict
  defp status_for(:voice_recording_sequence_gap), do: :conflict
  defp status_for(_reason), do: :bad_request

  defp code_for(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code_for(%Ecto.Changeset{}), do: "invalid_recording_chunk"
  defp code_for(_reason), do: "voice_recording_unavailable"

  defp recording_error(conn, status, code) do
    conn
    |> put_status(status)
    |> put_resp_content_type("application/json")
    |> json(%{error: code})
  end
end
