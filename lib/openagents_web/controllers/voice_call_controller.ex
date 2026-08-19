defmodule OpenAgentsWeb.VoiceCallController do
  use OpenAgentsWeb, :controller

  import Plug.Conn

  alias OpenAgents.Conversations
  alias OpenAgents.Voice.Config
  alias OpenAgents.Voice.OperationalTelemetry
  alias OpenAgents.VoiceSessions

  @maximum_sdp_bytes 65_536

  def create(conn, _params) do
    with %Config{enabled?: true} = config <- Config.current!(),
         {:ok, sdp_offer, conn} <- read_sdp(conn),
         %{status: "active"} = user <- conn.assigns.current_user,
         safety_identifier <- safety_identifier(user.id),
         {:ok, conversation} <- Conversations.ensure_conversation(user),
         :ok <- require_no_active_text_turn(conversation),
         {:ok, _session, admission} <-
           VoiceSessions.connect(conversation, sdp_offer, safety_identifier, config) do
      conn
      |> put_resp_content_type("application/sdp")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(:created, admission.answer_sdp)
    else
      %Config{enabled?: false} ->
        voice_error(conn, :service_unavailable, "voice_unavailable")

      {:error, :invalid_sdp} ->
        voice_error(conn, :bad_request, "invalid_sdp")

      {:error, :request_too_large} ->
        voice_error(conn, :request_entity_too_large, "invalid_sdp")

      {:error, :missing_api_key} ->
        voice_error(conn, :service_unavailable, "voice_unavailable")

      {:error, :voice_disabled} ->
        voice_error(conn, :service_unavailable, "voice_unavailable")

      {:error, :voice_draining} ->
        voice_error(conn, :service_unavailable, "voice_draining")

      {:error, :voice_capacity_reached} ->
        conn
        |> put_resp_header("retry-after", "30")
        |> voice_error(:service_unavailable, "voice_capacity_reached")

      {:error, :voice_session_in_progress} ->
        voice_error(conn, :conflict, "voice_session_in_progress")

      {:error, :text_turn_in_progress} ->
        voice_error(conn, :conflict, "text_turn_in_progress")

      {:error, :voice_rate_limited} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> voice_error(:too_many_requests, "voice_rate_limited")

      {:error, {:provider_rejected_call, _status}} ->
        voice_error(conn, :bad_gateway, "provider_rejected_call")

      {:error, {:http_status, status}} when status in 400..499 ->
        voice_error(conn, :bad_gateway, "provider_rejected_call")

      {:error, _reason} ->
        voice_error(conn, :bad_gateway, "voice_connection_failed")
    end
  end

  def delete(conn, _params) do
    with %{status: "active"} = user <- conn.assigns.current_user,
         {:ok, conversation} <- Conversations.ensure_conversation(user),
         session when not is_nil(session) <- OpenAgents.Voice.active_session(conversation),
         {:ok, _ended_session} <- VoiceSessions.end_session(session) do
      send_resp(conn, :no_content, "")
    else
      nil ->
        send_resp(conn, :no_content, "")

      {:error, _reason} ->
        voice_error(conn, :conflict, "voice_end_failed")
    end
  end

  def interrupt(conn, _params) do
    with %{status: "active"} = user <- conn.assigns.current_user,
         {:ok, conversation} <- Conversations.ensure_conversation(user),
         session when not is_nil(session) <- OpenAgents.Voice.active_session(conversation),
         {:ok, _interrupted_session} <- VoiceSessions.interrupt_session(session) do
      send_resp(conn, :no_content, "")
    else
      nil ->
        send_resp(conn, :no_content, "")

      {:error, :voice_not_responding} ->
        send_resp(conn, :no_content, "")

      {:error, _reason} ->
        voice_error(conn, :conflict, "voice_interrupt_unavailable")
    end
  end

  defp read_sdp(conn) do
    case read_body(conn, length: @maximum_sdp_bytes, read_length: 16_384) do
      {:ok, "v=0" <> _rest = body, next_conn} -> {:ok, body, next_conn}
      {:ok, _invalid, _next_conn} -> {:error, :invalid_sdp}
      {:more, _partial, _next_conn} -> {:error, :request_too_large}
      {:error, _reason} -> {:error, :invalid_sdp}
    end
  end

  defp safety_identifier(user_id) do
    :sha256
    |> :crypto.hash(user_id)
    |> Base.encode16(case: :lower)
  end

  defp require_no_active_text_turn(conversation) do
    case Conversations.active_turn(conversation) do
      nil -> :ok
      _active_turn -> {:error, :text_turn_in_progress}
    end
  end

  defp voice_error(conn, status, code) do
    :ok = OperationalTelemetry.admission_refused(admission_reason(code))

    conn
    |> put_status(status)
    |> put_resp_content_type("application/json")
    |> json(%{error: code})
  end

  defp admission_reason("voice_unavailable"), do: :voice_disabled
  defp admission_reason("voice_draining"), do: :voice_draining
  defp admission_reason("voice_capacity_reached"), do: :voice_capacity_reached
  defp admission_reason("voice_rate_limited"), do: :voice_rate_limited
  defp admission_reason("voice_session_in_progress"), do: :voice_session_in_progress
  defp admission_reason("text_turn_in_progress"), do: :text_turn_in_progress
  defp admission_reason("provider_rejected_call"), do: :provider_rejected_call
  defp admission_reason("voice_connection_failed"), do: :voice_connection_failed
  defp admission_reason(_code), do: :other
end
