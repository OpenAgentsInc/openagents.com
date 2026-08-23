defmodule OpenAgentsWeb.Plugs.DualPrincipalAuth do
  @moduledoc "Authenticates either a human forge token or an agent credential."

  import Plug.Conn

  alias OpenAgents.Agents
  alias OpenAgents.ApiTokens

  def init(options), do: Keyword.fetch!(options, :human_scope)

  def call(conn, human_scope) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- token != "",
         {:ok, principal} <- authenticate(token, human_scope) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> assign_principal(principal)
    else
      _ -> refuse(conn)
    end
  end

  defp authenticate("oa_agent_" <> _rest = token, _human_scope) do
    case Agents.authenticate(token, "agent:participate") do
      {:ok, agent, credential} -> {:ok, {:agent, agent, credential}}
      _ -> {:error, :invalid_token}
    end
  end

  defp authenticate(token, human_scope) do
    case ApiTokens.authenticate(token, human_scope) do
      {:ok, user, credential} -> {:ok, {:user, user, credential}}
      _ -> {:error, :invalid_token}
    end
  end

  defp assign_principal(conn, {:agent, agent, credential}) do
    conn
    |> assign(:current_agent, agent)
    |> assign(:agent_token, credential)
    |> assign(:api_scope, "agent:participate")
  end

  defp assign_principal(conn, {:user, user, credential}) do
    conn
    |> assign(:current_user, user)
    |> assign(:api_token, credential)
    |> assign(:api_scope, "forge:write")
  end

  defp refuse(conn) do
    conn
    |> put_status(:unauthorized)
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.json(%{"error" => "invalid_api_token"})
    |> halt()
  end
end
