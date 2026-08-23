defmodule OpenAgents.Tools.ComputerList do
  @moduledoc "Lists the computers the signed-in owner has paired with a controller."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.{Computer, Machines}
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, OwnerContext, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.computer_list.v1",
      name: "computer_list",
      version: 1,
      description:
        "Lists the computers the signed-in user has paired through the " <>
          "sarah-computer-controller CLI, including whether each one is currently connected. " <>
          "Use this before asking anything about the user's own computer.",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "computer.control",
      executor: %{
        id: "sarah.computer.registry",
        disclosure: "Paired computer records for the signed-in owner"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{
        "privacy" => "signed_browser_owner",
        "residency" => "application_process",
        "consent" => "not_applicable"
      },
      module_metadata:
        Metadata.first_party("computer.control", "browser_conversation",
          effect: :read_only,
          privacy: "signed_browser_owner",
          residency: "application_process"
        ),
      timeout_ms: 10_000,
      maximum_input_bytes: 256,
      maximum_output_bytes: 16_384,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(_arguments, context) do
    with {:ok, user} <- OwnerContext.resolve(context) do
      machines = Enum.map(Machines.list_machines(user.id), &summary/1)

      {:ok,
       %ExecutionResult{
         result: %{
           "schema" => "sarah.computer_list_result.v1",
           "status" => if(machines == [], do: "empty", else: "matches"),
           "machines" => machines
         },
         target_receipt_refs: Enum.map(machines, &"machine:#{&1["id"]}")
       }}
    end
  end

  defp summary(machine) do
    %{
      "id" => machine.id,
      "name" => machine.name,
      "tier" => machine.tier,
      "platform" => machine.platform || "unknown",
      "status" => machine.status,
      "connected" => Computer.online?(machine.id),
      "last_seen_at" => timestamp(machine.last_seen_at)
    }
  end

  defp timestamp(nil), do: "never"
  defp timestamp(value), do: DateTime.to_iso8601(value)

  defp input_schema do
    %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
  end

  defp output_schema do
    machine_schema = %{
      "type" => "object",
      "properties" => %{
        "id" => string(64),
        "name" => string(80),
        "tier" => string(16),
        "platform" => string(40),
        "status" => string(16),
        "connected" => %{"type" => "boolean"},
        "last_seen_at" => string(32)
      },
      "required" => ["id", "name", "tier", "platform", "status", "connected", "last_seen_at"],
      "additionalProperties" => false
    }

    %{
      "type" => "object",
      "properties" => %{
        "schema" => string(64),
        "status" => string(16),
        "machines" => %{"type" => "array", "maxItems" => 8, "items" => machine_schema}
      },
      "required" => ["schema", "status", "machines"],
      "additionalProperties" => false
    }
  end

  defp string(maximum), do: %{"type" => "string", "maxLength" => maximum}
end
