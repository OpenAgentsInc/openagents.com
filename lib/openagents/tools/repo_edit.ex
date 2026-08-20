defmodule OpenAgents.Tools.RepoEdit do
  @moduledoc """
  Exact-match edit inside this job's clone (SELF-EDIT-001): LF-normalized
  matching, zero matches is a typed error, multiple matches without
  replace_all asks for more context, and the file is re-read immediately
  before the write so a stale expectation fails as `no_match` instead of
  clobbering newer content.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Repository, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.repo_edit.v1",
      name: "repo_edit",
      version: 1,
      description:
        "Edits one file in this coding job's clone by exact string match. Pass path, " <>
          "old_string (must match exactly once unless replace_all), and new_string. " <>
          "Ambiguous matches are refused — include more surrounding context.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "maxLength" => 512},
          "old_string" => %{"type" => "string", "maxLength" => 100_000},
          "new_string" => %{"type" => "string", "maxLength" => 100_000},
          "replace_all" => %{"type" => "boolean"}
        },
        "required" => ["path", "old_string", "new_string"],
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
      side_effect: :reversible_write,
      required_scope: "browser_conversation",
      required_authority: "repository.write",
      executor: %{
        id: "sarah.repository.self",
        disclosure: "the OpenAgents runtime, editing this job's clone of her repository"
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
  def execute(
        %{"path" => path, "old_string" => old_string, "new_string" => new_string} = arguments,
        context
      )
      when is_binary(path) and is_binary(old_string) and is_binary(new_string) do
    replace_all = Map.get(arguments, "replace_all", false)

    with {:ok, workspace} <- Repository.tool_root("workspace", context),
         {:ok, resolved} <- Repository.safe_path(workspace, path),
         {:ok, content} <- read_regular(resolved),
         {:ok, updated, replaced} <-
           Repository.apply_edit(content, old_string, new_string, replace_all) do
      File.write!(resolved, updated)

      {:ok,
       %ExecutionResult{
         result: %{
           "schema" => "sarah.repo_edit_result.v1",
           "path" => path,
           "replacements" => replaced,
           "bytes" => byte_size(updated)
         },
         target_receipt_refs: ["repo-file:#{Repository.repo()}:#{path}"]
       }}
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_repository_path}

  defp read_regular(resolved) do
    if File.regular?(resolved) do
      {:ok, File.read!(resolved)}
    else
      {:error, :repository_file_not_found}
    end
  end
end
