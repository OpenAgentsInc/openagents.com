defmodule OpenAgentsWeb.Plugs.DeploymentPrincipal do
  @moduledoc """
  Builds the deployment principal for one request, from the credential alone.

  Two credentials reach the deployment API:

    * A first-party token carrying `deployments:write`, which authenticates a
      human. The token grants the *ability to speak to this API*; the repository
      and environment authority still comes from membership and policy.
    * A short-lived workflow grant (`oa_wfg_`), which authenticates a workflow
      run bound to one repository, ref, workflow, and run id.

  The principal is assigned once, here, and never derived from the request body,
  so a caller cannot claim a repository, an environment, or an operator role by
  sending one.
  """

  import Plug.Conn

  alias OpenAgents.ApiTokens
  alias OpenAgents.Deployments
  alias OpenAgents.Deployments.Principal

  @scope "deployments:write"

  def init(options), do: options

  def call(conn, _options) do
    case bearer(conn) do
      {:ok, "oa_wfg_" <> _rest = plaintext} -> workflow(conn, plaintext)
      {:ok, plaintext} -> human(conn, plaintext)
      {:error, _missing} -> refuse(conn)
    end
  end

  defp workflow(conn, plaintext) do
    case Deployments.authenticate_workflow_grant(plaintext) do
      {:ok, %Principal{} = principal} -> assign_principal(conn, principal, nil)
      {:error, _invalid} -> refuse(conn)
    end
  end

  defp human(conn, plaintext) do
    case ApiTokens.authenticate(plaintext, @scope) do
      {:ok, user, token} -> assign_principal(conn, Principal.user(user), {user, token})
      {:error, _denied} -> refuse(conn)
    end
  end

  defp assign_principal(conn, %Principal{} = principal, credential) do
    conn = conn |> put_resp_header("cache-control", "no-store") |> assign(:principal, principal)

    case credential do
      {user, token} -> conn |> assign(:current_user, user) |> assign(:api_token, token)
      nil -> conn
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _missing_or_ambiguous -> {:error, :missing_credential}
    end
  end

  defp refuse(conn) do
    conn
    |> put_status(:unauthorized)
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.json(%{
      "error" => %{"code" => "invalid_credential", "message" => "Invalid deployment credential"}
    })
    |> halt()
  end
end
