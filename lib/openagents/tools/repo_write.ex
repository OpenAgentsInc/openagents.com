defmodule OpenAgents.Tools.RepoWrite do
  @moduledoc "Writes one whole file inside this job's clone (SELF-EDIT-001)."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Repository, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.repo_write.v1",
      name: "repo_write",
      version: 1,
      description:
        "Creates or fully replaces one file in this coding job's clone. Pass path and the " <>
          "complete content. Prefer repo_edit for changes to existing files.",
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
      executor: %{
        id: "sarah.repository.self",
        disclosure: "the OpenAgents runtime, writing in this job's clone of her repository"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{
        "privacy" => "browser_conversation",
        "residency" => "host",
        "consent" => "job_goal"
      },
      module_metadata:
        Metadata.first_party("repository.write", "browser_conversation",
          effect: :reversible_write,
          privacy: "browser_conversation",
          residency: "host",
          surfaces: ["text"],
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
    with {:ok, workspace} <- Repository.tool_root("workspace", context),
         {:ok, resolved} <- Repository.safe_path(workspace, path) do
      File.mkdir_p!(Path.dirname(resolved))
      existed = File.regular?(resolved)
      File.write!(resolved, content)

      {:ok,
       %ExecutionResult{
         result: %{
           "schema" => "sarah.repo_write_result.v1",
           "path" => path,
           "action" => if(existed, do: "replaced", else: "created"),
           "bytes" => byte_size(content)
         },
         target_receipt_refs: ["repo-file:#{Repository.repo()}:#{path}"]
       }}
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_repository_path}
end
