defmodule OpenAgentsWeb.Plugs.ApiTokenAuth do
  @moduledoc "Authenticates a scoped first-party bearer credential for JSON APIs."

  import Plug.Conn

  alias OpenAgents.ApiTokens

  def init(options), do: Keyword.fetch!(options, :scope)

  def call(conn, required_scope) do
    with {:ok, plaintext} <- bearer(conn),
         {:ok, user, token} <- ApiTokens.authenticate(plaintext, required_scope) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> assign(:current_user, user)
      |> assign(:api_token, token)
      |> assign(:api_scope, required_scope)
    else
      _denied -> refuse(conn)
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _missing_or_ambiguous -> {:error, :missing_api_token}
    end
  end

  # A 401 from this pipeline is the first refusal an issue-family caller can
  # meet, so it carries the same envelope the controllers behind it use. The
  # `error` key predates the envelope and every measured client reads it, so it
  # rides beside the envelope rather than being replaced.
  defp refuse(conn) do
    body =
      OpenAgentsWeb.ApiError.envelope(conn, "unauthenticated",
        message: "Requires an API token with the scope this route needs",
        legacy: %{"error" => "invalid_api_token"}
      )

    conn
    |> put_status(:unauthorized)
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.json(body)
    |> halt()
  end
end
