defmodule OpenAgentsWeb.ComputersController do
  @moduledoc "Owner-authenticated JSON lifecycle for paired computers."

  use OpenAgentsWeb, :controller

  alias OpenAgents.Analytics
  alias OpenAgents.Computer
  alias OpenAgents.Machines
  alias OpenAgents.Machines.Machine

  def index(conn, _params) do
    computers =
      conn.assigns.current_user.id
      |> Machines.list_machines()
      |> Enum.map(&computer_projection/1)

    json(conn, %{
      "schema" => "openagents.computers.v1",
      "pairing_enabled" => Computer.enabled?(),
      "computers" => computers
    })
  end

  def approve_pairing(conn, %{"id" => pairing_id, "code" => code}) do
    if Computer.enabled?() do
      case Machines.approve_pairing(conn.assigns.current_user, pairing_id, code) do
        {:ok, machine} ->
          Analytics.capture(
            "computer_paired",
            Analytics.distinct_id(conn.assigns.current_user),
            %{"tier" => machine.tier}
          )

          json(conn, %{"computer" => computer_projection(machine)})

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
      {:ok, machine} -> json(conn, %{"computer" => computer_projection(machine)})
      {:error, :machine_not_found} -> error(conn, :not_found, "computer_not_found")
    end
  end

  defp pairing_error(conn, :pairing_not_found), do: error(conn, :not_found, "pairing_not_found")
  defp pairing_error(conn, :pairing_expired), do: error(conn, :gone, "pairing_expired")
  defp pairing_error(conn, :pairing_consumed), do: error(conn, :conflict, "pairing_consumed")

  defp pairing_error(conn, :too_many_machines),
    do: error(conn, :conflict, "computer_capacity_reached")

  defp pairing_error(conn, _reason), do: error(conn, :unprocessable_entity, "pairing_failed")

  defp error(conn, status, code) do
    conn |> put_status(status) |> json(%{"error" => code})
  end

  defp computer_projection(%Machine{} = machine) do
    %{
      "id" => machine.id,
      "name" => machine.name,
      "tier" => machine.tier,
      "status" => machine.status,
      "online" => machine.status == "active" and Computer.online?(machine.id),
      "platform" => machine.platform,
      "agent_version" => machine.agent_version,
      "roots" => machine.roots,
      "last_seen_at" => iso8601(machine.last_seen_at),
      "acp_agents" => acp_agents(machine.last_probe)
    }
  end

  defp acp_agents(%{"acp_agents" => agents}) when is_list(agents) do
    agents
    |> Enum.take(16)
    |> Enum.flat_map(fn
      %{"id" => id} = agent when is_binary(id) and id != "" ->
        [
          %{
            "id" => String.slice(id, 0, 64),
            "version" => bounded(agent["version"], 80),
            "source" => bounded(agent["source"], 40),
            "auth_ready" => boolean_or_nil(agent["auth_ready"]),
            "model" => bounded(agent["model"], 128),
            "reasoning_effort" => bounded(agent["reasoning_effort"], 32),
            "mode" => bounded(agent["mode"], 32)
          }
        ]

      _invalid ->
        []
    end)
  end

  defp acp_agents(_probe), do: []

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil

  defp bounded(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp bounded(_value, _maximum), do: nil

  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_value), do: nil
end
