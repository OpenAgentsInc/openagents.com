defmodule OpenAgentsWeb.Plugs.AssignmentControlAuth do
  @moduledoc "Authenticates human Box control or a granted agent principal."

  import Plug.Conn
  alias OpenAgents.Agents
  alias OpenAgents.ApiTokens

  def init(options), do: Keyword.get(options, :scope, "box:control")

  def call(conn, scope) do
    case get_req_header(conn, "authorization") do
      ["Bearer oa_agent_" <> _ = token] ->
        case Agents.authenticate(token, "agent:participate") do
          {:ok, agent, credential} ->
            if Agents.box_control_granted?(agent) do
              conn
              |> assign(:current_agent, agent)
              |> assign(:agent_token, credential)
              |> assign(:api_scope, "agent:participate")
            else
              refuse(conn, :forbidden, "agent_box_control_forbidden")
            end

          _ ->
            refuse(conn, :unauthorized, "invalid_api_token")
        end

      ["Bearer " <> token] when token != "" ->
        case ApiTokens.authenticate(token, scope) do
          {:ok, user, credential} ->
            conn
            |> assign(:current_user, user)
            |> assign(:api_token, credential)
            |> assign(:api_scope, scope)

          _ ->
            refuse(conn, :unauthorized, "invalid_api_token")
        end

      _ ->
        refuse(conn, :unauthorized, "invalid_api_token")
    end
  end

  defp refuse(conn, status, code) do
    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.json(%{"error" => %{"code" => code}})
    |> halt()
  end
end
