defmodule OpenAgentsWeb.ForgeUserController do
  @moduledoc "Reports the authenticated GitHub identity and eligible repository namespaces."

  use OpenAgentsWeb, :controller

  alias OpenAgents.Repositories.GitHubProjection

  def show(conn, _params) do
    user = conn.assigns.current_user

    case GitHubProjection.available_namespaces(user) do
      {:ok, namespaces} ->
        json(conn, %{
          "id" => user.github_id,
          "login" => user.github_login,
          "token_expires_at" => DateTime.to_iso8601(conn.assigns.api_token.expires_at),
          "namespaces" =>
            Enum.map(namespaces, fn namespace ->
              %{
                "id" => namespace.provider_account_id,
                "login" => namespace.slug,
                "type" => namespace.kind
              }
            end)
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
