defmodule OpenAgents.Tools.ComputerProbe do
  @moduledoc """
  Asks a paired computer what it has: host facts, coding agents, and toolchains.

  Read-only. The controller runs a fixed discovery set locally and refuses
  anything else; if the machine is offline the outcome is typed rather than
  imagined.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.{Computer, Machines}
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, OwnerContext, Tool}

  @maximum_entries 40

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.computer_probe.v1",
      name: "computer_probe",
      version: 1,
      description:
        "Discovers what is installed on one of the user's paired computers: operating system, " <>
          "coding agents (claude, codex, cursor-agent, aider and similar), and toolchains " <>
          "(git, node, python, cargo and similar), including each ACP agent's configured " <>
          "model, reasoning effort, and mode when declared. Pass machine_id from computer_list. " <>
          "Discovery is read-only; it never changes the machine.",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "computer.control",
      executor: %{
        id: "sarah.computer.controller",
        disclosure: "Read-only discovery on the user's paired computer"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com", "OpenAgentsInc/sarah-computer-controller"],
      policy_facets: %{
        "privacy" => "signed_browser_owner",
        "residency" => "operator_machine",
        "consent" => "machine_pairing"
      },
      module_metadata:
        Metadata.first_party("computer.control", "browser_conversation",
          effect: :read_only,
          privacy: "signed_browser_owner",
          residency: "operator_machine"
        ),
      timeout_ms: 20_000,
      maximum_input_bytes: 512,
      maximum_output_bytes: 32_768,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"machine_id" => machine_id}, context) when is_binary(machine_id) do
    with {:ok, user} <- OwnerContext.resolve(context),
         {:ok, machine} <- Machines.get_machine(user.id, machine_id) do
      case probe(machine) do
        {:ok, report, freshness} ->
          {:ok,
           %ExecutionResult{
             result: %{
               "schema" => "sarah.computer_probe_result.v1",
               "status" => "ok",
               "machine_id" => machine.id,
               "machine_name" => machine.name,
               "freshness" => freshness,
               "platform" => text(report["platform"], 60),
               "release" => text(report["release"], 80),
               "architecture" => text(report["architecture"], 30),
               "shell" => text(report["shell"], 80),
               "acp_agents" => acp_agents(report["acp_agents"]),
               "coding_agents" => present(report["coding_agents"]),
               "toolchains" => present(report["toolchains"])
             },
             target_receipt_refs: ["machine:#{machine.id}"]
           }}

        {:error, reason} ->
          {:ok,
           %ExecutionResult{
             result: %{
               "schema" => "sarah.computer_probe_result.v1",
               "status" => Atom.to_string(reason),
               "machine_id" => machine.id,
               "machine_name" => machine.name,
               "freshness" => "unavailable",
               "platform" => "unknown",
               "release" => "unknown",
               "architecture" => "unknown",
               "shell" => "unknown",
               "acp_agents" => [],
               "coding_agents" => [],
               "toolchains" => []
             },
             target_receipt_refs: ["machine:#{machine.id}"]
           }}
      end
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_machine_reference}

  defp probe(machine) do
    case Computer.request_probe(machine.id) do
      {:ok, report} ->
        {:ok, report, "live"}

      {:error, reason} ->
        case machine.last_probe do
          report when is_map(report) -> {:ok, report, "last_known"}
          _absent -> {:error, reason}
        end
    end
  end

  defp present(entries) when is_list(entries) do
    entries
    |> Enum.filter(&(is_map(&1) and &1["present"] == true))
    |> Enum.take(@maximum_entries)
    |> Enum.map(
      &%{
        "name" => text(&1["name"], 40),
        "path" => text(&1["path"], 200),
        "version" => text(&1["version"], 60)
      }
    )
  end

  defp present(_entries), do: []

  defp acp_agents(entries) when is_list(entries) do
    entries
    |> Enum.take(@maximum_entries)
    |> Enum.flat_map(fn
      %{"id" => id} = agent when is_binary(id) and id != "" ->
        [
          %{
            "id" => text(id, 64),
            "source" => text(agent["source"], 40),
            "version" => text(agent["version"], 80),
            "model" => optional_text(agent["model"], 128, "default"),
            "reasoning_effort" => optional_text(agent["reasoning_effort"], 32, "default"),
            "mode" => optional_text(agent["mode"], 32, "default")
          }
        ]

      _invalid ->
        []
    end)
  end

  defp acp_agents(_entries), do: []

  defp optional_text(value, maximum, _fallback) when is_binary(value) and value != "",
    do: String.slice(value, 0, maximum)

  defp optional_text(_value, _maximum, fallback), do: fallback

  defp text(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp text(_value, _maximum), do: "unknown"

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{"machine_id" => %{"type" => "string", "maxLength" => 64}},
      "required" => ["machine_id"],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    entry_schema = %{
      "type" => "object",
      "properties" => %{
        "name" => string(40),
        "path" => string(200),
        "version" => string(60)
      },
      "required" => ["name", "path", "version"],
      "additionalProperties" => false
    }

    entries = %{"type" => "array", "maxItems" => @maximum_entries, "items" => entry_schema}

    acp_entry_schema = %{
      "type" => "object",
      "properties" => %{
        "id" => string(64),
        "source" => string(40),
        "version" => string(80),
        "model" => string(128),
        "reasoning_effort" => string(32),
        "mode" => string(32)
      },
      "required" => ["id", "source", "version", "model", "reasoning_effort", "mode"],
      "additionalProperties" => false
    }

    acp_entries = %{
      "type" => "array",
      "maxItems" => @maximum_entries,
      "items" => acp_entry_schema
    }

    %{
      "type" => "object",
      "properties" => %{
        "schema" => string(64),
        "status" => string(32),
        "machine_id" => string(64),
        "machine_name" => string(80),
        "freshness" => string(16),
        "platform" => string(60),
        "release" => string(80),
        "architecture" => string(30),
        "shell" => string(80),
        "acp_agents" => acp_entries,
        "coding_agents" => entries,
        "toolchains" => entries
      },
      "required" => [
        "schema",
        "status",
        "machine_id",
        "machine_name",
        "freshness",
        "platform",
        "release",
        "architecture",
        "shell",
        "acp_agents",
        "coding_agents",
        "toolchains"
      ],
      "additionalProperties" => false
    }
  end

  defp string(maximum), do: %{"type" => "string", "maxLength" => maximum}
end
