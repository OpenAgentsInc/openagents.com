defmodule OpenAgentsWeb.CoderIdentityController do
  @moduledoc "Returns the authenticated account projection Coder needs."

  use OpenAgentsWeb, :controller

  alias OpenAgents.Repositories.GitHubProjection

  def show(conn, _params) do
    user = conn.assigns.current_user

    case GitHubProjection.available_repositories(user) do
      {:ok, repositories} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(%{
          "github_id" => user.github_id,
          "login" => user.github_login,
          "repositories" => repositories
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp render_error(conn, :github_connection_required),
    do: error(conn, :forbidden, "github_connection_required", "Connect GitHub to continue")

  defp render_error(conn, :github_scope_required),
    do: error(conn, :forbidden, "github_scope_required", "Reconnect GitHub with required access")

  defp render_error(conn, _reason),
    do: error(conn, :service_unavailable, "github_unavailable", "GitHub is unavailable")

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      "code" => code,
      "message" => message,
      "request_id" => List.first(get_resp_header(conn, "x-request-id"))
    })
  end
end
