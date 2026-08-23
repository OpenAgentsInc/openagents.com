defmodule OpenAgentsWeb.ComputersController do
  @moduledoc "Owner-authenticated JSON lifecycle for paired computers."

  use OpenAgentsWeb, :controller

  alias OpenAgents.Analytics
  alias OpenAgents.Computer
  alias OpenAgents.ComputerProjection
  alias OpenAgents.Machines
  alias OpenAgents.Machines.Machine

  def index(conn, _params) do
    computers =
      conn.assigns.current_user.id
      |> Machines.list_machines()
      |> Enum.map(&ComputerProjection.project/1)

    json(conn, %{
      "schema" => "openagents.computers.v1",
      "pairing_enabled" => Computer.enabled?(),
      "computers" => computers
    })
  end

  def update(conn, %{"id" => machine_id} = params) do
    case Map.fetch(params, "scoped_forge_credentials_enabled") do
      {:ok, value} when value in [true, "true", "1", false, "false", "0"] ->
        enabled = value in [true, "true", "1"]

        case Machines.update_scoped_forge_credentials(
               conn.assigns.current_user,
               machine_id,
               enabled
             ) do
          {:ok, machine} -> json(conn, %{"computer" => ComputerProjection.project(machine)})
          {:error, :machine_not_found} -> error(conn, :not_found, "computer_not_found")
        end

      _invalid ->
        error(conn, :unprocessable_entity, "invalid_scoped_forge_credentials_policy")
    end
  end

  def update(conn, _params), do: error(conn, :not_found, "computer_not_found")

  def probe(conn, %{"computer_id" => computer_id}) do
    with {:ok, machine} <- Machines.get_machine(conn.assigns.current_user.id, computer_id),
         :ok <- probe_enabled(),
         :ok <- probe_active(machine),
         {:ok, report} <- Computer.request_probe(machine.id),
         {:ok, machine} <- Machines.store_probe(machine, report) do
      json(conn, %{"computer" => ComputerProjection.project(machine)})
    else
      {:error, :machine_not_found} ->
        error(conn, :not_found, "computer_not_found")

      {:error, :computer_controller_disabled} ->
        error(conn, :not_found, "computer_controller_disabled")

      {:error, :machine_revoked} ->
        error(conn, :conflict, "computer_revoked")

      {:error, :machine_offline} ->
        error(conn, :conflict, "computer_offline")

      {:error, _reason} ->
        error(conn, :bad_gateway, "computer_probe_failed")
    end
  end

  def probe(conn, _params), do: error(conn, :not_found, "computer_not_found")

  def approve_pairing(conn, %{"id" => pairing_id, "code" => code}) do
    if Computer.enabled?() do
      case Machines.approve_pairing(conn.assigns.current_user, pairing_id, code,
             scoped_forge_credentials_enabled:
               params_boolean(conn.params["scoped_forge_credentials_enabled"])
           ) do
        {:ok, machine} ->
          Analytics.capture(
            "computer_paired",
            Analytics.distinct_id(conn.assigns.current_user),
            %{"tier" => machine.tier}
          )

          json(conn, %{"computer" => ComputerProjection.project(machine)})

        {:error, reason} ->
          pairing_error(conn, reason)
      end
    else
      error(conn, :not_found, "computer_controller_disabled")
    end
  end

  def approve_pairing(conn, _params), do: error(conn, :unprocessable_entity, "invalid_pairing")

  def delete(conn, %{"id" => machine_id}) do
    case Machines.revoke_machine(conn.assigns.current_user, machine_id) do
      {:ok, machine} -> json(conn, %{"computer" => ComputerProjection.project(machine)})
      {:error, :machine_not_found} -> error(conn, :not_found, "computer_not_found")
    end
  end

  defp pairing_error(conn, :pairing_not_found), do: error(conn, :not_found, "pairing_not_found")
  defp pairing_error(conn, :pairing_expired), do: error(conn, :gone, "pairing_expired")
  defp pairing_error(conn, :pairing_consumed), do: error(conn, :conflict, "pairing_consumed")

  defp pairing_error(conn, :too_many_machines),
    do: error(conn, :conflict, "computer_capacity_reached")

  defp pairing_error(conn, _reason), do: error(conn, :unprocessable_entity, "pairing_failed")

  defp probe_enabled do
    if Computer.enabled?(), do: :ok, else: {:error, :computer_controller_disabled}
  end

  defp probe_active(%Machine{status: "active"}), do: :ok
  defp probe_active(%Machine{}), do: {:error, :machine_revoked}

  defp error(conn, status, code) do
    conn |> put_status(status) |> json(%{"error" => code})
  end

  defp params_boolean(value) when value in [true, "true", "1"], do: true
  defp params_boolean(_value), do: false
end
