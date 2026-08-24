defmodule OpenAgents.ComputerProjection do
  @moduledoc """
  Safe projection of a paired computer for API and product surfaces.

  Everything here is the owner's own record of their own computer. What stays
  out is what IDENTITY-008 keeps out: the computer token, its digest, and the
  raw probe document.

  `revoked_at` is included because `status` alone answers half the question.
  Every other credential in this release publishes both — `api_tokens`,
  `inference_grants`, `agent_tokens`, `forge_assignment_credentials` — and this
  was the one terminal stamp the database held and nothing read, so an account
  export could tell you a computer was revoked and never when.
  """

  alias OpenAgents.Computer
  alias OpenAgents.Machines.Machine

  @spec project(Machine.t()) :: map()
  def project(%Machine{} = machine) do
    %{
      "id" => machine.id,
      "name" => machine.name,
      "tier" => machine.tier,
      "status" => machine.status,
      "revoked_at" => iso8601(machine.revoked_at),
      "scoped_forge_credentials_enabled" => machine.scoped_forge_credentials_enabled,
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
