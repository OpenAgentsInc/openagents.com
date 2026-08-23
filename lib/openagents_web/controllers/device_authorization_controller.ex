defmodule OpenAgentsWeb.DeviceAuthorizationController do
  @moduledoc "Creates and polls short-lived CLI browser authorizations."

  use OpenAgentsWeb, :controller

  alias OpenAgents.{ApiTokens, DeviceAuthorizations}

  def create(conn, params) do
    case DeviceAuthorizations.create(requested_scopes(params)) do
      {:ok, authorization, device_code, user_code} ->
        verification_uri = OpenAgentsWeb.Endpoint.url() <> "/device"

        conn
        |> put_status(:created)
        |> no_store()
        |> json(%{
          "device_code" => device_code,
          "user_code" => user_code,
          "verification_uri" => verification_uri,
          "verification_uri_complete" =>
            verification_uri <> "?" <> URI.encode_query(%{"user_code" => user_code}),
          "expires_in" => DateTime.diff(authorization.expires_at, DateTime.utc_now(), :second),
          "interval" => authorization.interval_seconds,
          "scope" => Enum.join(authorization.scopes, " ")
        })

      {:error, %Ecto.Changeset{}} ->
        error(conn, :bad_request, "invalid_scope")

      {:error, :invalid_scopes} ->
        error(conn, :bad_request, "invalid_scope")

      {:error, _reason} ->
        error(conn, :service_unavailable, "authorization_unavailable")
    end
  end

  # A device authorization may request any real scope, including the
  # operator-only one. Approval, not this parameter, decides whether the
  # requester may hold it.
  defp requested_scopes(params) do
    case params["scope"] || params["scopes"] do
      scope when is_binary(scope) -> String.split(scope, " ", trim: true)
      scopes when is_list(scopes) -> Enum.filter(scopes, &(&1 in ApiTokens.allowed_scopes()))
      _absent -> ["forge:write"]
    end
  end

  def token(conn, %{"device_code" => device_code}) do
    case DeviceAuthorizations.poll(device_code) do
      {:ok, plaintext, api_token} ->
        conn
        |> no_store()
        |> json(%{
          "access_token" => plaintext,
          "token_type" => "Bearer",
          "scope" => Enum.join(api_token.scopes, " "),
          "expires_in" => DateTime.diff(api_token.expires_at, DateTime.utc_now(), :second)
        })

      {:error, :authorization_pending} ->
        error(conn, :precondition_required, "authorization_pending")

      {:error, :slow_down} ->
        error(conn, :too_many_requests, "slow_down")

      {:error, :authorization_unavailable} ->
        error(conn, :service_unavailable, "authorization_unavailable")

      {:error, _reason} ->
        error(conn, :bad_request, "access_denied")
    end
  end

  def token(conn, _params), do: error(conn, :bad_request, "access_denied")

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> no_store()
    |> json(%{"code" => code})
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
