defmodule OpenAgentsWeb.Plugs.AgentTokenAuth do
  @moduledoc "Authenticates an agent participation credential."

  import Plug.Conn

  alias OpenAgents.Agents

  def init(options), do: Keyword.get(options, :scope, "agent:participate")

  def call(conn, required_scope) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, agent, credential} <- Agents.authenticate(token, required_scope) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> assign(:current_agent, agent)
      |> assign(:agent_token, credential)
      |> assign(:agent_scope, required_scope)
    else
      _ -> refuse(conn)
    end
  end

  defp refuse(conn) do
    conn
    |> put_status(:unauthorized)
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.json(%{"error" => "invalid_agent_token"})
    |> halt()
  end
end
