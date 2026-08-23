defmodule OpenAgents.Tools.ComputerDevin do
  @moduledoc """
  Delegates a coding task to the Devin agent running on a paired computer.

  Deprecated: superseded by `OpenAgents.Tools.ComputerAgent` (`computer_agent.v1`),
  which delegates to any ACP agent named in the computer's probe inventory.
  This tool keeps working for one release and now rides the same generic
  `agent` channel request with `agent_id` `"devin"`.

  The controller speaks the Agent Client Protocol (ACP v1) to a local
  `devin acp` subprocess: it negotiates the protocol version, opens a session
  in a folder the user shared, sends the prompt, streams the agent's progress
  back, and answers the agent's permission requests from the computer's own
  policy tier. Nothing here can widen what that tier permits, and the
  subprocess is killed on cancellation, timeout, or disconnection.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.{Computer, Machines}
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, OwnerContext, Tool}

  @maximum_output_characters 12_000
  @maximum_timeout_ms 480_000
  @default_timeout_ms 300_000

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.computer_devin.v1",
      name: "computer_devin",
      version: 1,
      description:
        "Deprecated: use computer_agent with agent_id \"devin\" instead. " <>
          "Asks the Devin coding agent on one of the user's paired computers to do a coding task. " <>
          "Pass machine_id from computer_list (Devin must appear in its coding agents) and a " <>
          "prompt describing the task. Optional: cwd (absolute path inside the computer's shared " <>
          "folders), session_id to continue an earlier Devin session (long tasks should be " <>
          "resumed across turns with it), and timeout_ms. Returns " <>
          "Devin's streamed output plus a session id for follow-up work. If Devin is missing or " <>
          "not signed in, the status says so rather than guessing.",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :external_effect,
      required_scope: "browser_conversation",
      required_authority: "computer.control",
      executor: %{
        id: "sarah.computer.controller.acp",
        disclosure:
          "Devin coding agent on the user's paired computer, over the Agent Client Protocol"
      },
      maintainer: "OpenAgents",
      attribution: [
        "OpenAgentsInc/openagents.com",
        "OpenAgentsInc/sarah-computer-controller",
        "agentclientprotocol/agent-client-protocol"
      ],
      policy_facets: %{
        "privacy" => "signed_browser_owner",
        "residency" => "operator_machine",
        "consent" => "machine_pairing"
      },
      module_metadata:
        Metadata.first_party("computer.control", "browser_conversation",
          effect: :external_effect,
          approval_class: "explicit_operator_approval",
          privacy: "signed_browser_owner",
          residency: "operator_machine"
        ),
      timeout_ms: 510_000,
      maximum_input_bytes: 16_384,
      maximum_output_bytes: 65_536,
      implementation: __MODULE__,
      reach: [:signed_in_owner, :paired_computer]
    }
  end

  @impl true
  def execute(%{"machine_id" => machine_id, "prompt" => prompt} = arguments, context)
      when is_binary(machine_id) and is_binary(prompt) do
    with :ok <- validate_prompt(prompt),
         {:ok, user} <- OwnerContext.resolve(context),
         {:ok, machine} <- Machines.get_machine(user.id, machine_id) do
      timeout_ms = bounded_timeout(arguments["timeout_ms"])

      payload =
        %{"prompt" => prompt, "timeout_ms" => timeout_ms}
        |> put_optional("cwd", arguments["cwd"])
        |> put_optional("session_id", arguments["session_id"])

      case Computer.request_devin(machine.id, payload, timeout_ms + 15_000) do
        {:ok, exit_payload} -> {:ok, result(machine, exit_payload)}
        {:refused, reason, detail} -> {:ok, refusal(machine, reason, detail)}
        {:error, reason} -> {:ok, failure(machine, reason)}
      end
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_delegation_request}

  defp validate_prompt(prompt) do
    trimmed = String.trim(prompt)

    if trimmed != "" and byte_size(prompt) <= 8_000,
      do: :ok,
      else: {:error, :invalid_delegation_request}
  end

  defp bounded_timeout(value) when is_integer(value) and value > 0,
    do: min(value, @maximum_timeout_ms)

  defp bounded_timeout(_value), do: @default_timeout_ms

  defp put_optional(payload, _key, nil), do: payload

  defp put_optional(payload, key, value) when is_binary(value) and value != "",
    do: Map.put(payload, key, String.slice(value, 0, 500))

  defp put_optional(payload, _key, _value), do: payload

  defp result(machine, exit_payload) do
    base(machine, text(exit_payload["status"], 32))
    |> put_in_result("stop_reason", text(exit_payload["stop_reason"], 32))
    |> put_in_result("session_id", text(exit_payload["session_id"], 128))
    |> put_in_result("output", output(exit_payload["output"]))
    |> put_in_result("truncated", exit_payload["truncated"] == true)
    |> put_in_result("duration_ms", integer(exit_payload["duration_ms"]))
    |> put_in_result("detail", text(exit_payload["detail"], 500))
  end

  defp refusal(machine, reason, detail) do
    base(machine, "refused")
    |> put_in_result("detail", String.slice("#{reason}: #{detail}", 0, 500))
  end

  defp failure(machine, reason), do: base(machine, Atom.to_string(reason))

  defp base(machine, status) do
    %ExecutionResult{
      result: %{
        "schema" => "sarah.computer_devin_result.v1",
        "status" => status,
        "machine_id" => machine.id,
        "machine_name" => machine.name,
        "stop_reason" => "",
        "session_id" => "",
        "output" => "",
        "truncated" => false,
        "duration_ms" => 0,
        "detail" => ""
      },
      target_receipt_refs: ["machine:#{machine.id}"]
    }
  end

  defp put_in_result(%ExecutionResult{result: result} = execution, key, value),
    do: %ExecutionResult{execution | result: Map.put(result, key, value)}

  defp output(value) when is_binary(value), do: String.slice(value, 0, @maximum_output_characters)
  defp output(_value), do: ""

  defp text(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp text(_value, _maximum), do: ""

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: 0

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "machine_id" => %{"type" => "string", "maxLength" => 64},
        "prompt" => %{"type" => "string", "maxLength" => 8_000},
        "cwd" => %{"type" => "string", "maxLength" => 500},
        "session_id" => %{"type" => "string", "maxLength" => 128},
        "timeout_ms" => %{"type" => "integer", "minimum" => 1, "maximum" => @maximum_timeout_ms}
      },
      "required" => ["machine_id", "prompt"],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "schema" => %{"type" => "string", "maxLength" => 64},
        "status" => %{"type" => "string", "maxLength" => 32},
        "machine_id" => %{"type" => "string", "maxLength" => 64},
        "machine_name" => %{"type" => "string", "maxLength" => 80},
        "stop_reason" => %{"type" => "string", "maxLength" => 32},
        "session_id" => %{"type" => "string", "maxLength" => 128},
        "output" => %{"type" => "string", "maxLength" => @maximum_output_characters},
        "truncated" => %{"type" => "boolean"},
        "duration_ms" => %{"type" => "integer"},
        "detail" => %{"type" => "string", "maxLength" => 500}
      },
      "required" => [
        "schema",
        "status",
        "machine_id",
        "machine_name",
        "stop_reason",
        "session_id",
        "output",
        "truncated",
        "duration_ms",
        "detail"
      ],
      "additionalProperties" => false
    }
  end
end
