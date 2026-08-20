defmodule OpenAgents.Tools.TestRecall do
  @moduledoc false

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.recall_messages",
      name: "recall_messages",
      version: 1,
      description: "Searches messages in the current browser conversation",
      input_schema: %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string", "maxLength" => 200}},
        "required" => ["query"],
        "additionalProperties" => false
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "matches" => %{
            "type" => "array",
            "items" => %{"type" => "string", "maxLength" => 200},
            "maxItems" => 5
          }
        },
        "required" => ["matches"],
        "additionalProperties" => false
      },
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "conversation.read",
      executor: %{id: "sarah.local.recall", disclosure: "Sarah local conversation recall"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{"privacy" => "browser_scoped"},
      module_metadata:
        Metadata.first_party("conversation.read", "browser_conversation",
          effect: :read_only,
          privacy: "browser_scoped",
          residency: "host"
        ),
      timeout_ms: 5_000,
      maximum_input_bytes: 2_048,
      maximum_output_bytes: 8_192,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"query" => query}, context) do
    if observer = Application.get_env(:openagents, :test_tool_observer) do
      send(observer, {:test_tool_executed, self(), query, context.scope_ref})
    end

    if query == "block" do
      receive do
        :release_test_tool -> :ok
      after
        10_000 -> :ok
      end
    end

    {:ok,
     %ExecutionResult{
       result: %{"matches" => ["Found #{query} in this conversation."]},
       target_receipt_refs: ["message:test-match"]
     }}
  end
end
