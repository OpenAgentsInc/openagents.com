defmodule OpenAgentsWeb.Plugs.BoxControlAuth do
  @moduledoc "Authenticates a human bearer credential with Box control authority."

  import Plug.Conn

  alias OpenAgents.Agents
  alias OpenAgents.ApiTokens

  def init(options), do: Keyword.fetch!(options, :scope)

  def call(conn, required_scope) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- token != "" do
      authenticate(conn, token, required_scope)
    else
      _ -> refuse(conn, :unauthorized, "invalid_api_token")
    end
  end

  defp authenticate(conn, "oa_agent_" <> _rest = token, _required_scope) do
    case Agents.authenticate(token, "agent:participate") do
      {:ok, _agent, _credential} ->
        refuse(conn, :forbidden, "agent_box_control_forbidden")

      _ ->
        refuse(conn, :unauthorized, "invalid_api_token")
    end
  end

  defp authenticate(conn, token, required_scope) do
    case ApiTokens.authenticate(token, required_scope) do
      {:ok, user, credential} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> assign(:current_user, user)
        |> assign(:api_token, credential)
        |> assign(:api_scope, required_scope)

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
