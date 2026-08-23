defmodule OpenAgents.Tools.BoxNew do
  @moduledoc """
  Provisions a new Box VM for this conversation and bootstraps OpenCode on it.

  The pool caps active boxes per conversation, so a runaway loop cannot
  provision unbounded machines. The OpenRouter credential travels through the
  box environment, never through this tool's arguments or result.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Box
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "openagents.tool.box_new.v1",
      name: "box_new",
      version: 1,
      description:
        "Provisions a new Box VM for this conversation, waits for it to become runnable, " <>
          "and installs the OpenCode agent harness configured for OpenRouter. A conversation " <>
          "holds at most #{Box.maximum_active_boxes()} active boxes; stop one with box_stop " <>
          "to free a slot. Drive the box with box_exec.",
      input_schema: %{
        "type" => "object",
        "properties" => %{},
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
      timeout_ms: 90_000,
      maximum_input_bytes: 256,
      maximum_output_bytes: 4_096,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(_arguments, context) do
    case Box.create_box(context.conversation_id) do
      {:ok, record} ->
        {:ok,
         %ExecutionResult{
           result: %{
             "schema" => "openagents.box_new_result.v1",
             "box_id" => record.box_id,
             "state" => record.state,
             "setup_status" => record.setup_status
           },
           status: if(record.setup_status == "failed", do: "failed", else: "succeeded"),
           error:
             if(record.setup_status == "failed",
               do: %{
                 "code" => "box_setup_failed",
                 "message" =>
                   "The box is running but the OpenCode setup script failed. " <>
                     "Inspect it with box_exec or stop it with box_stop."
               }
             ),
           target_receipt_refs: ["box:#{record.box_id}"]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
