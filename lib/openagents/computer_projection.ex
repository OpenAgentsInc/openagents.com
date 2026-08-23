defmodule OpenAgents.ComputerProjection do
  @moduledoc "Safe projection of a paired computer for API and product surfaces."

  alias OpenAgents.Computer
  alias OpenAgents.Machines.Machine

  @spec project(Machine.t()) :: map()
  def project(%Machine{} = machine) do
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
