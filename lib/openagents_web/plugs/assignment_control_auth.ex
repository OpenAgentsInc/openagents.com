defmodule OpenAgentsWeb.Plugs.AssignmentControlAuth do
  @moduledoc "Authenticates human or delegated control for one target kind."

  import Plug.Conn
  alias OpenAgents.Agents
  alias OpenAgents.ApiTokens

  def init(options) do
    %{
      scope: Keyword.get(options, :scope, "box:control"),
      target_kind: Keyword.get(options, :target_kind, "box")
    }
  end

  def call(conn, %{scope: scope, target_kind: target_kind}) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" ->
        if String.starts_with?(token, "oa_agent_") do
          authenticate_agent(conn, token, target_kind)
        else
          authenticate_human(conn, token, scope)
        end

      _ ->
        refuse(conn, :unauthorized, "invalid_api_token")
    end
  end

  def call(conn, scope) when is_binary(scope),
    do: call(conn, %{scope: scope, target_kind: "box"})

  defp forbidden_code("computer"), do: "agent_computer_control_forbidden"
  defp forbidden_code(_target_kind), do: "agent_box_control_forbidden"

  defp authenticate_agent(conn, token, target_kind) do
    case Agents.authenticate(token, "agent:participate") do
      {:ok, agent, credential} ->
        case Agents.control_owner(agent, target_kind) do
          %OpenAgents.Accounts.User{} = owner ->
            conn
            |> assign(:current_user, owner)
            |> assign(:current_agent, agent)
            |> assign(:agent_token, credential)
            |> assign(:api_scope, "agent:participate")

          nil ->
            refuse(conn, :forbidden, forbidden_code(target_kind))
        end

      _ ->
        refuse(conn, :unauthorized, "invalid_api_token")
    end
  end

  defp authenticate_human(conn, token, scope) do
    case ApiTokens.authenticate(token, scope) do
      {:ok, user, credential} ->
        conn
        |> assign(:current_user, user)
        |> assign(:api_token, credential)
        |> assign(:api_scope, scope)

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
