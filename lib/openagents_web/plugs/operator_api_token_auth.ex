defmodule OpenAgentsWeb.Plugs.OperatorApiTokenAuth do
  @moduledoc """
  Authenticates a privileged bearer credential *and* live operator standing.

  Two conditions hold on every request, never one:

  1. The token carries the exact privileged scope. A token holding every other
     scope in the system is refused with `401`, indistinguishable from a
     missing, expired, revoked, or malformed credential.
  2. `OpenAgents.Accounts.admin?/1` is true for the token's owner *now*.
     Removing an account from the operator allowlist therefore takes effect on
     the next request rather than at token expiry, and is answered with `403`
     so an operator whose standing was withdrawn can tell why.

  Authority is never inferred from a login, a repository membership, a Git
  push credential, or the ordinary `forge:write` scope.
  """

  import Plug.Conn

  alias OpenAgents.{Accounts, ApiTokens, Audit}
  alias OpenAgentsWeb.ApiError

  def init(options), do: Keyword.fetch!(options, :scope)

  def call(conn, required_scope) do
    with {:ok, plaintext} <- bearer(conn),
         {:ok, user, token} <- ApiTokens.authenticate(plaintext, required_scope),
         :ok <- operator(user, token, required_scope) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> assign(:current_user, user)
      |> assign(:api_token, token)
      |> assign(:api_scope, required_scope)
    else
      {:error, :not_operator} ->
        refuse(conn, "not_operator")

      _denied ->
        refuse(conn, "unauthenticated",
          message: "Requires an API token carrying deployments:promote",
          legacy: %{"error" => "invalid_api_token"}
        )
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _missing_or_ambiguous -> {:error, :missing_api_token}
    end
  end

  defp operator(user, token, required_scope) do
    if Accounts.admin?(user) do
      :ok
    else
      Audit.record!("api_token.operator_denied", {:user, user.id}, "api_token", token.id,
        metadata: %{"scope" => required_scope}
      )

      {:error, :not_operator}
    end
  end

  # This pipeline's refusal is the first one an operator client can meet, so it
  # carries the same envelope the controller behind it uses.
  defp refuse(conn, code, options \\ []) do
    body = ApiError.envelope(conn, code, options)

    conn
    |> put_status(ApiError.codes()[code])
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.json(body)
    |> halt()
  end
end
