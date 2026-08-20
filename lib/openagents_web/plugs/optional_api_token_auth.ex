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

  defp refuse(conn) do
    conn
    |> put_status(:unauthorized)
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.json(%{"error" => "invalid_api_token"})
    |> halt()
  end
end
