defmodule OpenAgentsWeb.CoderGrantController do
  @moduledoc """
  Mints a signed spending grant for the authenticated account.

  The grant is an Ed25519-signed JWT with the `coder-grant` audience that
  Coder validates locally, so accepting one costs Coder no OpenAgents call.
  `OpenAgents.CoderGrant` owns the claims, the amount bounds, and the signing;
  this controller only maps its answers onto the API.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.CoderGrant

  def create(conn, params) do
    user = conn.assigns.current_user

    case requested_amount(params) do
      :invalid ->
        error(
          conn,
          :unprocessable_entity,
          "invalid_amount",
          "amount_microusd must be a positive integer"
        )

      requested ->
        mint(conn, user, requested)
    end
  end

  defp mint(conn, user, requested) do
    case CoderGrant.mint(user, requested) do
      {:ok, grant} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(%{
          "grant" => grant.token,
          "grant_id" => grant.jti,
          "audience" => "coder-grant",
          "amount_microusd" => grant.amount_microusd,
          "expires_in" => grant.expires_in
        })

      {:error, :insufficient_credit} ->
        error(
          conn,
          :payment_required,
          "insufficient_credit",
          "The account has no credit left to grant"
        )

      {:error, reason} when reason in [:signing_key_unconfigured, :signing_key_invalid] ->
        error(
          conn,
          :service_unavailable,
          "coder_grant_unavailable",
          "Coder grant signing is not configured"
        )
    end
  end

  # A bounded integer field, parsed only after the route has been selected.
  defp requested_amount(params) do
    case Map.get(params, "amount_microusd") do
      nil -> nil
      amount when is_integer(amount) and amount > 0 -> amount
      _invalid -> :invalid
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
