defmodule OpenAgentsWeb.VoiceTelemetryController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Conversations
  alias OpenAgents.Voice.{BrowserIdentity, Config}

  def create(conn, %{"kind" => kind}) do
    with %Config{enabled?: true} <- Config.current!(),
         %{status: "active"} = user <- conn.assigns.current_user,
         conversation when not is_nil(conversation) <-
           Conversations.get_conversation_for_user(user),
         session when not is_nil(session) <- OpenAgents.Voice.active_session(conversation),
         browser <- BrowserIdentity.parse(get_req_header(conn, "user-agent") |> List.first()),
         {:ok, _event} <- OpenAgents.Voice.record_client_event(session, kind, browser) do
      send_resp(conn, :no_content, "")
    else
      %Config{enabled?: false} -> send_resp(conn, :no_content, "")
      nil -> send_resp(conn, :no_content, "")
      {:error, :voice_client_event_limit_reached} -> send_resp(conn, :too_many_requests, "")
      {:error, %Ecto.Changeset{}} -> send_resp(conn, :bad_request, "")
      {:error, _reason} -> send_resp(conn, :no_content, "")
      _unavailable -> send_resp(conn, :no_content, "")
    end
  end

  def create(conn, _params), do: send_resp(conn, :bad_request, "")
end
