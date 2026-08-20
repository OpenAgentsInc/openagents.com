defmodule OpenAgentsWeb.ApiTokenController do
  @moduledoc "Browser-authenticated issuance and revocation of first-party API credentials."

  use OpenAgentsWeb, :controller

  alias OpenAgents.ApiTokens

  def index(conn, _params) do
    tokens = conn.assigns.current_user |> ApiTokens.metadata() |> Enum.map(&projection/1)
    conn |> put_resp_header("cache-control", "no-store") |> json(%{"tokens" => tokens})
  end

  def create(conn, params) do
    case ApiTokens.create(conn.assigns.current_user, params) do
      {:ok, token, plaintext} ->
        conn
        |> put_status(:created)
        |> put_resp_header("cache-control", "no-store")
        |> json(%{
          "token" => plaintext,
          "credential" => projection(token),
          "warning" => "This token is shown once. Store it securely."
        })

      {:error, _invalid} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_resp_header("cache-control", "no-store")
        |> json(%{"error" => "invalid_api_token"})
    end
  end

  def delete(conn, %{"id" => id}) do
    case ApiTokens.revoke(conn.assigns.current_user, id) do
      {:ok, token} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(%{"credential" => projection(token)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_resp_header("cache-control", "no-store")
        |> json(%{"error" => "not_found"})
    end
  end

  defp projection(token) do
    %{
      "id" => token.id,
      "name" => token.name,
      "scopes" => token.scopes,
      "expires_at" => iso8601(token.expires_at),
      "last_used_at" => iso8601(token.last_used_at),
      "revoked_at" => iso8601(token.revoked_at)
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(value), do: DateTime.to_iso8601(value)
end
