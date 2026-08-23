defmodule OpenAgentsWeb.Plugs.MachineTokenAuth do
  @moduledoc "Authenticates a paired-machine bearer credential."

  import Plug.Conn

  alias OpenAgents.Machines

  def init(options), do: options

  def call(conn, _options) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" ->
        authenticate(conn, token)

      _missing_or_ambiguous ->
        refuse(conn, "invalid_machine_token")
    end
  end

  defp authenticate(conn, token) do
    case Machines.authenticate_token(token) do
      {:ok, machine} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> assign(:current_machine, machine)

      {:error, :machine_revoked} ->
        refuse(conn, "machine_revoked")

      {:error, :machine_expired} ->
        refuse(conn, "machine_expired")

      {:error, :machine_not_found} ->
        refuse(conn, "machine_not_found")
    end
  end

  defp refuse(conn, code) do
    conn
    |> put_status(:unauthorized)
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.json(%{"error" => code})
    |> halt()
  end
end
