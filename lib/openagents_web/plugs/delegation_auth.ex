defmodule OpenAgentsWeb.Plugs.DelegationAuth do
  @moduledoc "Authenticates either control scope for the unified delegation API."

  import Plug.Conn

  alias OpenAgents.Agents
  alias OpenAgents.ApiTokens

  def init(options), do: options

  def call(conn, _options) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" ->
        authenticate(token, conn)

      _missing ->
        refuse(conn, :unauthorized, "invalid_api_token")
    end
  end

  defp authenticate("oa_agent_" <> _rest = token, conn) do
    case Agents.authenticate(token, "agent:participate") do
      {:ok, agent, credential} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> assign(:current_agent, agent)
        |> assign(:agent_token, credential)
        |> assign(:delegation_scopes, [])

      _invalid ->
        refuse(conn, :unauthorized, "invalid_api_token")
    end
  end

  defp authenticate(token, conn) do
    with {:error, _box} <- authenticate_human(token, "box:control"),
         {:error, _computer} <- authenticate_human(token, "computer:control") do
      refuse(conn, :unauthorized, "invalid_api_token")
    else
      {:ok, user, credential} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> assign(:current_user, user)
        |> assign(:api_token, credential)
        |> assign(:delegation_scopes, credential.scopes)
    end
  end

  defp authenticate_human(token, scope), do: ApiTokens.authenticate(token, scope)

  defp refuse(conn, status, code) do
    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.json(%{"error" => %{"code" => code}})
    |> halt()
  end
end
