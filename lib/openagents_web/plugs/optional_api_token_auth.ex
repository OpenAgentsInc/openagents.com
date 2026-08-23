defmodule OpenAgentsWeb.Plugs.OptionalApiTokenAuth do
  @moduledoc "Authenticates a supplied first-party bearer credential and permits anonymous requests."

  import Plug.Conn

  alias OpenAgents.ApiTokens

  def init(options), do: Keyword.fetch!(options, :scope)

  def call(conn, required_scope) do
    case get_req_header(conn, "authorization") do
      [] ->
        assign(conn, :current_user, nil)

      ["Bearer " <> token] when token != "" ->
        authenticate(conn, token, required_scope)

      _invalid ->
        refuse(conn)
    end
  end

  defp authenticate(conn, token, required_scope) do
    case ApiTokens.authenticate(token, required_scope) do
      {:ok, user, api_token} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> assign(:current_user, user)
        |> assign(:api_token, api_token)
        |> assign(:api_scope, required_scope)

      {:error, :invalid_api_token} ->
        refuse(conn)
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
