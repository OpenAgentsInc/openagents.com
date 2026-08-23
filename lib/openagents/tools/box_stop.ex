defmodule OpenAgents.Tools.BoxStop do
  @moduledoc """
  Stops and archives a conversation-owned Box VM.

  Stopping snapshots the box and frees a slot in the conversation's box
  quota. The box remains resumable on the provider side.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Box
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "openagents.tool.box_stop.v1",
      name: "box_stop",
      version: 1,
      description:
        "Stops and archives one of this conversation's Box VMs, freeing a slot in the " <>
          "conversation's box quota. Files persist in a snapshot.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "box_id" => %{"type" => "string", "maxLength" => 32}
        },
        "required" => ["box_id"],
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
      timeout_ms: 30_000,
      maximum_input_bytes: 512,
      maximum_output_bytes: 4_096,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"box_id" => box_id}, context) when is_binary(box_id) do
    case Box.stop_box(context.conversation_id, box_id) do
      {:ok, record} ->
        {:ok,
         %ExecutionResult{
           result: %{
             "schema" => "openagents.box_stop_result.v1",
             "box_id" => record.box_id,
             "state" => record.state,
             "stopped_at" => DateTime.to_iso8601(record.stopped_at)
           },
           target_receipt_refs: ["box:#{record.box_id}"]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :box_not_owned}
end
