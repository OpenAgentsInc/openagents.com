defmodule OpenAgents.Tools.BoxExec do
  @moduledoc """
  Runs one shell command on a conversation-owned Box VM.

  The command runs remotely through the Box command endpoint and returns the
  standard exit status with bounded, redacted output. Ownership is checked
  before the request leaves the host, so a box id from another conversation
  refuses without a remote call.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Box
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{BoxOutput, ExecutionResult, Tool}

  @default_timeout_seconds 60
  # The registry caps a tool run at 600 seconds; the remote command budget
  # stays below it so the HTTP round trip fits inside the tool budget.
  @maximum_timeout_seconds 570

  @impl true
  def specification do
    %Tool{
      module_id: "openagents.tool.box_exec.v1",
      name: "box_exec",
      version: 1,
      description:
        "Runs one shell command on one of this conversation's Box VMs and returns its exit " <>
          "code with bounded stdout and stderr. Use `opencode run \"<task>\"` to drive the " <>
          "installed OpenCode harness. Get box ids from box_list or box_new.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "box_id" => %{"type" => "string", "maxLength" => 32},
          "command" => %{"type" => "string", "maxLength" => 4_000},
          "timeout_seconds" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @maximum_timeout_seconds
          }
        },
        "required" => ["box_id", "command"],
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
      side_effect: :reversible_write,
      required_scope: "browser_conversation",
      required_authority: "box.control",
      executor: %{id: "ascii.box", disclosure: "the Box VM service at ascii.dev"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{"privacy" => "browser_conversation", "residency" => "external_provider"},
      module_metadata:
        Metadata.first_party("box.control", "browser_conversation",
          effect: :reversible_write,
          privacy: "browser_conversation",
          residency: "external_provider",
          surfaces: ["text", "voice"],
          approval_class: "exact_current_user_consent",
          approval_enforcement: "executor_consent"
        ),
      timeout_ms: (@maximum_timeout_seconds + 30) * 1_000,
      maximum_input_bytes: 8_192,
      maximum_output_bytes: 64 * 1_024,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"box_id" => box_id, "command" => command} = arguments, context)
      when is_binary(box_id) and is_binary(command) do
    with :ok <- validate_command(command),
         {:ok, timeout_seconds} <- timeout_seconds(arguments),
         {:ok, body} <-
           Box.run_command(context.conversation_id, box_id, command, timeout_seconds) do
      build_result(box_id, body)
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_command}

  defp validate_command(command) do
    cond do
      String.trim(command) == "" -> {:error, :invalid_command}
      not String.valid?(command) -> {:error, :invalid_command}
      String.contains?(command, "\0") -> {:error, :invalid_command}
      true -> :ok
    end
  end

  defp timeout_seconds(arguments) do
    case Map.get(arguments, "timeout_seconds", @default_timeout_seconds) do
      seconds when is_integer(seconds) and seconds >= 1 and seconds <= @maximum_timeout_seconds ->
        {:ok, seconds}

      _invalid ->
        {:error, :invalid_command_timeout}
    end
  end

  defp build_result(box_id, body) do
    {stdout, stdout_truncated} = BoxOutput.bounded(body["stdout"])
    {stderr, stderr_truncated} = BoxOutput.bounded(body["stderr"])
    exit_code = body["exitCode"]
    timed_out = body["timedOut"] == true

    status =
      cond do
        timed_out -> "failed"
        exit_code == 0 -> "succeeded"
        true -> "failed"
      end

    {:ok,
     %ExecutionResult{
       result: %{
         "schema" => "openagents.box_exec_result.v1",
         "box_id" => box_id,
         "exit_code" => exit_code,
         "signal" => body["signal"],
         "timed_out" => timed_out,
         "stdout" => stdout,
         "stderr" => stderr,
         "stdout_truncated" => stdout_truncated or body["stdoutTruncated"] == true,
         "stderr_truncated" => stderr_truncated or body["stderrTruncated"] == true
       },
       status: status,
       error:
         if(status == "failed",
           do: %{
             "code" => if(timed_out, do: "command_timed_out", else: "command_failed"),
             "message" =>
               if(timed_out,
                 do: "The command did not finish within the requested timeout.",
                 else: "The command exited with a nonzero status."
               )
           }
         ),
       target_receipt_refs: ["box:#{box_id}"]
     }}
  end
end
