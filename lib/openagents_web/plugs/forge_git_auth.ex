defmodule OpenAgentsWeb.Plugs.ForgeGitAuth do
  @moduledoc """
  Optional HTTP Basic authentication for Git endpoints. Repository policy is
  evaluated after path resolution by `OpenAgents.Forge.GitHTTP`.
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
    case basic_credentials(conn) do
      :missing ->
        assign(conn, :forge_principal, nil)

      {:ok, {_user, password}} ->
        case principal_for(password) do
          {:ok, principal} -> assign(conn, :forge_principal, principal)
          :error -> refuse(conn)
        end

      :error ->
        refuse(conn)
    end
  end

  defp basic_credentials(conn) do
    with ["Basic " <> encoded | _] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [user, password] <- String.split(decoded, ":", parts: 2) do
      {:ok, {user, password}}
    else
      [] -> :missing
      _ -> :error
    end
  end

  defp principal_for("oa_pat_" <> _ = token) do
    case OpenAgents.ApiTokens.authenticate(token, "forge:write") do
      {:ok, user, api_token} ->
        {:ok, %{kind: :user, id: user.id, user: user, api_token_id: api_token.id}}

      {:error, :invalid_api_token} ->
        :error
    end
  end

  defp principal_for("smct_" <> _ = token) do
    case OpenAgents.Machines.authenticate_token(token) do
      {:ok, machine} -> {:ok, %{kind: :machine, id: machine.id}}
      {:error, _} -> :error
    end
  end

  defp principal_for("oa_assignment_" <> _ = token) do
    case OpenAgents.Forge.Assignments.authenticate(token) do
      {:ok, principal} -> {:ok, principal}
      _ -> :error
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

  defp refuse(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="openagents-forge"))
    |> send_resp(401, "authentication required")
    |> halt()
  end
end
