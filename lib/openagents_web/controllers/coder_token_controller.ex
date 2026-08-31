defmodule OpenAgentsWeb.CoderTokenController do
  @moduledoc """
  Mints a short-lived Coder-audience token for the authenticated account.

  The token is an Ed25519-signed JWT that Coder validates locally, so the
  claims never depend on Phoenix's symmetric secret. `OpenAgents.CoderToken`
  owns the signing; this controller only maps its answers onto the API.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.CoderToken

  def create(conn, _params) do
    user = conn.assigns.current_user

    case CoderToken.mint(user) do
      {:ok, token} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(%{
          "token" => token,
          "audience" => "coder",
          "expires_in" => CoderToken.ttl_seconds()
        })

      {:error, :github_connection_required} ->
        error(conn, :forbidden, "github_connection_required", "Connect GitHub to continue")

      {:error, reason} when reason in [:signing_key_unconfigured, :signing_key_invalid] ->
        error(
          conn,
          :service_unavailable,
          "coder_token_unavailable",
          "Coder token signing is not configured"
        )
    end
  end

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
