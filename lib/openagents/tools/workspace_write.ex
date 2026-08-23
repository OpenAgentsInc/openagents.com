defmodule OpenAgents.Tools.WorkspaceWrite do
  @moduledoc "Creates or replaces a file in an explicit, noncanonical agent workspace."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Tool, WorkspaceFiles}

  @impl true
  def specification do
    %Tool{
      module_id: "openagents.tool.workspace_write.v1",
      name: "write",
      version: 1,
      description: "Creates or replaces one UTF-8 file in the assigned agent workspace.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "maxLength" => 512},
          "content" => %{"type" => "string", "maxLength" => 200_000}
        },
        "required" => ["path", "content"],
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
      side_effect: :reversible_write,
      required_scope: "browser_conversation",
      required_authority: "repository.write",
      executor: %{id: "openagents.workspace", disclosure: "the assigned agent workspace"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{"privacy" => "browser_conversation", "residency" => "host"},
      module_metadata:
        Metadata.first_party("repository.write", "browser_conversation",
          effect: :reversible_write,
          privacy: "browser_conversation",
          residency: "host",
          surfaces: ["text", "voice"],
          approval_class: "exact_current_user_consent",
          approval_enforcement: "host_receipt"
        ),
      timeout_ms: 10_000,
      maximum_input_bytes: 262_144,
      maximum_output_bytes: 16_384,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"path" => path, "content" => content}, context)
      when is_binary(path) and is_binary(content) do
    with true <- String.valid?(content),
         {:ok, target} <- WorkspaceFiles.resolve(context, path, :write),
         {:ok, result} <-
           WorkspaceFiles.serialize(target, fn -> WorkspaceFiles.atomic_write(target, content) end) do
      {:ok,
       %ExecutionResult{
         result: Map.put(result, "schema", "openagents.workspace_write_result.v1"),
         target_receipt_refs: [result["effect_receipt"], result["snapshot_ref"]]
       }}
    else
      false -> {:error, :workspace_invalid_encoding}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_workspace_path}
end
