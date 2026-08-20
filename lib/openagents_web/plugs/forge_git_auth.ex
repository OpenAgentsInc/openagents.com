defmodule OpenAgentsWeb.Plugs.ForgeGitAuth do
  @moduledoc """
  HTTP basic auth for the forge's git endpoints. The password is the
  credential (the username is ignored, as git clients vary): a paired
  machine token (`smct_…`, verified through `OpenAgents.Machines`) or the
  operator forge token from runtime configuration. No anonymous access.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if OpenAgents.Forge.enabled?() do
      authenticate(conn)
    else
      conn |> send_resp(404, "not found") |> halt()
    end
  end

  defp authenticate(conn) do
    with {_user, password} <- basic_credentials(conn),
         {:ok, principal} <- principal_for(password) do
      assign(conn, :forge_principal, principal)
    else
      _ ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="openagents-forge"))
        |> send_resp(401, "authentication required")
        |> halt()
    end
  end

  defp basic_credentials(conn) do
    with ["Basic " <> encoded | _] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [user, password] <- String.split(decoded, ":", parts: 2) do
      {user, password}
    else
      _ -> :error
    end
  end

  defp principal_for("smct_" <> _ = token) do
    case OpenAgents.Machines.authenticate_token(token) do
      {:ok, machine} -> {:ok, %{kind: :machine, id: machine.id}}
      {:error, _} -> :error
    end
  end

  defp principal_for(token) when is_binary(token) and token != "" do
    operator_token = Application.get_env(:openagents, :forge_operator_token)

    if is_binary(operator_token) and operator_token != "" and
         Plug.Crypto.secure_compare(token, operator_token) do
      {:ok, %{kind: :operator, id: "forge-token"}}
    else
      :error
    end
  end

  defp principal_for(_), do: :error
end
