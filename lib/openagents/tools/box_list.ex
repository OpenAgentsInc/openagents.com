defmodule OpenAgents.Tools.BoxList do
  @moduledoc "Lists the Box VMs this conversation has provisioned."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Box
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "openagents.tool.box_list.v1",
      name: "box_list",
      version: 1,
      description:
        "Lists this conversation's Box VMs with each box's id, lifecycle state, OpenCode " <>
          "setup status, and creation time. Use it before box_exec or box_stop.",
      input_schema: %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      },
      output_schema: output_schema(),
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "box.control",
      executor: %{id: "ascii.box", disclosure: "the Box VM service at ascii.dev"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{"privacy" => "browser_conversation", "residency" => "external_provider"},
      module_metadata:
        Metadata.first_party("box.control", "browser_conversation",
          effect: :read_only,
          privacy: "browser_conversation",
          residency: "external_provider",
          surfaces: ["text", "voice"]
        ),
      timeout_ms: 30_000,
      maximum_input_bytes: 256,
      maximum_output_bytes: 16_384,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(_arguments, context) do
    boxes = Enum.map(Box.list_boxes(context.conversation_id), &summary/1)

    {:ok,
     %ExecutionResult{
       result: %{
         "schema" => "openagents.box_list_result.v1",
         "status" => if(boxes == [], do: "empty", else: "matches"),
         "boxes" => boxes
       },
       target_receipt_refs: Enum.map(boxes, &"box:#{&1["box_id"]}")
     }}
  end

  defp summary(record) do
    base = %{
      "box_id" => record.box_id,
      "state" => record.state,
      "setup_status" => record.setup_status,
      "created_at" => DateTime.to_iso8601(record.inserted_at)
    }

    case record.stopped_at do
      %DateTime{} = stopped_at -> Map.put(base, "stopped_at", DateTime.to_iso8601(stopped_at))
      nil -> base
    end
  end

  defp output_schema do
    box_schema = %{
      "type" => "object",
      "properties" => %{
        "box_id" => %{"type" => "string", "maxLength" => 32},
        "state" => %{"type" => "string", "maxLength" => 16},
        "setup_status" => %{"type" => "string", "maxLength" => 16},
        "created_at" => %{"type" => "string", "maxLength" => 40},
        "stopped_at" => %{"type" => "string", "maxLength" => 40}
      },
      "required" => ["box_id", "state", "setup_status", "created_at"],
      "additionalProperties" => false
    }

    %{
      "type" => "object",
      "properties" => %{
        "schema" => %{"type" => "string", "maxLength" => 64},
        "status" => %{"type" => "string", "maxLength" => 16},
        "boxes" => %{"type" => "array", "maxItems" => 100, "items" => box_schema}
      },
      "required" => ["schema", "status", "boxes"],
      "additionalProperties" => false
    }
  end
end
