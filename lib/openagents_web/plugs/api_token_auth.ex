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

  defp refuse(conn) do
    conn
    |> put_status(:unauthorized)
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.json(%{"error" => "invalid_api_token"})
    |> halt()
  end
end
