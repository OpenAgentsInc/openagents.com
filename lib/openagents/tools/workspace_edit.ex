defmodule OpenAgents.Tools.WorkspaceEdit do
  @moduledoc "Applies an atomic batch of exact edits in an explicit agent workspace."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Tool, WorkspaceFiles}

  @impl true
  def specification do
    %Tool{
      module_id: "openagents.tool.workspace_edit.v1",
      name: "edit",
      version: 1,
      description:
        "Atomically applies exact, nonoverlapping edits to one workspace file. Each old_text " <>
          "must occur exactly once in the original content.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "maxLength" => 512},
          "expected_digest" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"},
          "edits" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => 100,
            "items" => %{
              "type" => "object",
              "properties" => %{
                "old_text" => %{"type" => "string", "maxLength" => 100_000},
                "new_text" => %{"type" => "string", "maxLength" => 100_000}
              },
              "required" => ["old_text", "new_text"],
              "additionalProperties" => false
            }
          }
        },
        "required" => ["path", "expected_digest", "edits"],
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
  def execute(
        %{"path" => path, "expected_digest" => expected_digest, "edits" => edits},
        context
      )
      when is_binary(path) and is_binary(expected_digest) and is_list(edits) and edits != [] do
    with {:ok, target} <- WorkspaceFiles.resolve(context, path, :write) do
      WorkspaceFiles.serialize(target, fn -> edit_locked(target, expected_digest, edits) end)
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_edits}

  defp edit_locked(target, expected_digest, edits) do
    with {:ok, original} <- WorkspaceFiles.read_regular(target),
         ^expected_digest <- WorkspaceFiles.digest(original),
         {:ok, updated, replacements} <- WorkspaceFiles.exact_edits(original, edits),
         {:ok, result} <- WorkspaceFiles.atomic_write(target, updated) do
      {:ok,
       %ExecutionResult{
         result:
           result
           |> Map.put("schema", "openagents.workspace_edit_result.v1")
           |> Map.put("replacements", replacements),
         target_receipt_refs: [result["effect_receipt"], result["snapshot_ref"]]
       }}
    else
      digest when is_binary(digest) -> {:error, :stale_workspace_digest}
      {:error, reason} -> {:error, reason}
    end
  end
end
