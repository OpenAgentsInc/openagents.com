defmodule OpenAgents.Tools.PublishChanges do
  @moduledoc "Publishes all chat workspace changes to an assigned Forge branch."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Tool, WorkspacePublication}

  @impl true
  def specification do
    %Tool{
      module_id: "openagents.tool.publish_changes.v1",
      name: "publish_changes",
      version: 1,
      description:
        "Commit all current workspace changes and publish them to the chat run's assigned " <>
          "OpenAgents Forge branch. The server chooses the repository, remote, and branch.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "message" => %{"type" => "string", "minLength" => 1, "maxLength" => 2_000},
          "expected_workspace_digest" => %{
            "type" => "string",
            "pattern" => "^[0-9a-f]{64}$"
          }
        },
        "required" => ["message"],
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
      side_effect: :external_effect,
      required_scope: "browser_conversation",
      required_authority: "repository.write",
      executor: %{
        id: "openagents.forge.workspace_publication",
        disclosure: "the OpenAgents runtime, publishing an isolated chat branch to its own Forge"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{
        "privacy" => "browser_conversation",
        "residency" => "host",
        "consent" => "explicit_publication"
      },
      module_metadata:
        Metadata.first_party("repository.write", "browser_conversation",
          effect: :external_effect,
          privacy: "browser_conversation",
          residency: "host",
          surfaces: ["text"],
          approval_class: "explicit_operator_approval",
          approval_enforcement: "host_receipt"
        ),
      timeout_ms: 60_000,
      maximum_input_bytes: 8_192,
      maximum_output_bytes: 32_768,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"message" => message} = arguments, context) do
    case WorkspacePublication.publish(
           context,
           String.trim(message),
           Map.get(arguments, "expected_workspace_digest")
         ) do
      {:ok, result} ->
        receipt = result["receipt"]

        {:ok,
         %ExecutionResult{
           result: result,
           target_receipt_refs: [
             "repository-publication:#{result["publication_id"]}",
             "forge-commit:#{result["repository"]}:#{result["published_oid"]}",
             "forge-branch:#{result["repository"]}:#{result["branch"]}",
             "forge-push:#{result["repository"]}:#{receipt["wal_seq"]}"
           ]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
