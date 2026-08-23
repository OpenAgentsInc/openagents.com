defmodule OpenAgents.Tools.ComputerRun do
  @moduledoc """
  Runs one command on one of the user's paired computers.

  The command is a typed argv array — never a shell string — and the
  controller's local policy is the final authority: a computer paired at a
  lower tier, a denied command, or a path outside its declared roots comes
  back as a typed refusal, not an execution. Output is streamed on the
  computer, collected bounded here, and secret-shaped text is masked before
  it ever leaves the computer.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.{Computer, Machines}
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, OwnerContext, Tool}

  @maximum_output_characters 12_000
  @maximum_timeout_ms 110_000

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.computer_run.v1",
      name: "computer_run",
      version: 1,
      description:
        "Runs one command on one of the user's paired computers and returns its output and " <>
          "exit code. Pass machine_id from computer_list and the command as an argv array " <>
          "(for example [\"git\", \"status\"]) — shell syntax like pipes or && is not supported. " <>
          "The computer's own policy can refuse a command; a refusal names the reason. " <>
          "Optional: cwd (absolute path inside the computer's shared folders) and timeout_ms.",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :external_effect,
      required_scope: "browser_conversation",
      required_authority: "computer.control",
      executor: %{
        id: "sarah.computer.controller",
        disclosure: "Command execution on the user's paired computer, bounded by its local policy"
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
          effect: :external_effect,
          approval_class: "explicit_operator_approval",
          privacy: "signed_browser_owner",
          residency: "operator_machine"
        ),
      timeout_ms: 120_000,
      maximum_input_bytes: 8_192,
      maximum_output_bytes: 65_536,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"machine_id" => machine_id, "argv" => argv} = arguments, context)
      when is_binary(machine_id) and is_list(argv) do
    with :ok <- validate_argv(argv),
         {:ok, user} <- OwnerContext.resolve(context),
         {:ok, machine} <- Machines.get_machine(user.id, machine_id) do
      timeout_ms = bounded_timeout(arguments["timeout_ms"])

      payload =
        %{"argv" => argv, "timeout_ms" => timeout_ms}
        |> put_optional("cwd", arguments["cwd"])

      case Computer.request_run(machine.id, payload, timeout_ms + 10_000) do
        {:ok, exit_payload} ->
          {:ok, result(machine, exit_payload)}

        {:refused, reason, detail} ->
          {:ok, refusal(machine, reason, detail)}

        {:error, reason} ->
          {:ok, failure(machine, reason)}
      end
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_command_request}

  defp validate_argv([_command | _arguments] = argv) do
    if Enum.all?(argv, &(is_binary(&1) and byte_size(&1) <= 2_000)) and length(argv) <= 64,
      do: :ok,
      else: {:error, :invalid_command_request}
  end

  defp validate_argv(_argv), do: {:error, :invalid_command_request}

  defp bounded_timeout(value) when is_integer(value) and value > 0,
    do: min(value, @maximum_timeout_ms)

  defp bounded_timeout(_value), do: 30_000

  defp put_optional(payload, _key, nil), do: payload

  defp put_optional(payload, key, value) when is_binary(value),
    do: Map.put(payload, key, String.slice(value, 0, 500))

  defp put_optional(payload, _key, _value), do: payload

  defp result(machine, exit_payload) do
    %ExecutionResult{
      result: %{
        "schema" => "sarah.computer_run_result.v1",
        "status" => text(exit_payload["status"], 32),
        "machine_id" => machine.id,
        "machine_name" => machine.name,
        "exit_code" => integer(exit_payload["exit_code"]),
        "output" => output(exit_payload["output"]),
        "truncated" => exit_payload["truncated"] == true,
        "duration_ms" => integer(exit_payload["duration_ms"]),
        "detail" => text(exit_payload["detail"], 500)
      },
      target_receipt_refs: ["machine:#{machine.id}"]
    }
  end

  defp refusal(machine, reason, detail) do
    %ExecutionResult{
      result: %{
        "schema" => "sarah.computer_run_result.v1",
        "status" => "refused",
        "machine_id" => machine.id,
        "machine_name" => machine.name,
        "exit_code" => -1,
        "output" => "",
        "truncated" => false,
        "duration_ms" => 0,
        "detail" => String.slice("#{reason}: #{detail}", 0, 500)
      },
      target_receipt_refs: ["machine:#{machine.id}"]
    }
  end

  defp failure(machine, reason) do
    %ExecutionResult{
      result: %{
        "schema" => "sarah.computer_run_result.v1",
        "status" => Atom.to_string(reason),
        "machine_id" => machine.id,
        "machine_name" => machine.name,
        "exit_code" => -1,
        "output" => "",
        "truncated" => false,
        "duration_ms" => 0,
        "detail" => ""
      },
      target_receipt_refs: ["machine:#{machine.id}"]
    }
  end

  defp output(value) when is_binary(value), do: String.slice(value, 0, @maximum_output_characters)
  defp output(_value), do: ""

  defp text(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp text(_value, _maximum), do: ""

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: -1

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "machine_id" => %{"type" => "string", "maxLength" => 64},
        "argv" => %{
          "type" => "array",
          "items" => %{"type" => "string", "maxLength" => 2_000},
          "minItems" => 1,
          "maxItems" => 64
        },
        "cwd" => %{"type" => "string", "maxLength" => 500},
        "timeout_ms" => %{"type" => "integer", "minimum" => 1, "maximum" => @maximum_timeout_ms}
      },
      "required" => ["machine_id", "argv"],
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
        "exit_code" => %{"type" => "integer"},
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
        "exit_code",
        "output",
        "truncated",
        "duration_ms",
        "detail"
      ],
      "additionalProperties" => false
    }
  end
end
