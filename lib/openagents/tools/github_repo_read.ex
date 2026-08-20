defmodule OpenAgents.Tools.GitHubRepoRead do
  @moduledoc "Reads a file or directory from a GitHub repository with the user's OAuth token."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.GitHub
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, GitHubContext, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.github_repo_read.v1",
      name: "github_repo_read",
      version: 1,
      description:
        "Reads a file or lists a directory inside a GitHub repository the signed-in user can " <>
          "access. Pass repository as owner/name, path as a repo-relative path (empty string " <>
          "for the root), and ref as a branch, tag, or commit (empty string for the default " <>
          "branch).",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "github.read",
      executor: %{id: "sarah.github.api", disclosure: "GitHub API with the user's authorization"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{
        "privacy" => "signed_browser_owner",
        "residency" => "application_process",
        "consent" => "not_applicable"
      },
      module_metadata:
        Metadata.first_party("github.read", "browser_conversation",
          effect: :read_only,
          privacy: "signed_browser_owner",
          residency: "application_process"
        ),
      timeout_ms: 15_000,
      maximum_input_bytes: 2_048,
      maximum_output_bytes: 131_072,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"repository" => repository, "path" => path, "ref" => ref}, context)
      when is_binary(repository) and is_binary(path) and is_binary(ref) do
    with {:ok, token, _user} <- GitHubContext.resolve(context),
         {:ok, contents} <- GitHub.read_path(token, repository, path, ref) do
      {:ok,
       %ExecutionResult{
         result:
           Map.merge(contents, %{
             "schema" => "sarah.github_repo_read_result.v1",
             "scope" => "signed_github_user",
             "repository" => repository
           }),
         target_receipt_refs: ["github-repo:#{repository}"]
       }}
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_repository}

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "repository" => %{"type" => "string", "maxLength" => 140},
        "path" => %{"type" => "string", "maxLength" => 500},
        "ref" => %{"type" => "string", "maxLength" => 100}
      },
      "required" => ["repository", "path", "ref"],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    entry_schema = %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "maxLength" => 255},
        "path" => %{"type" => "string", "maxLength" => 500},
        "type" => %{"type" => "string", "maxLength" => 16},
        "size" => %{"type" => "integer"}
      },
      "required" => ["name", "path", "type", "size"],
      "additionalProperties" => false
    }

    %{
      "type" => "object",
      "properties" => %{
        "schema" => %{"type" => "string", "maxLength" => 64},
        "scope" => %{"type" => "string", "maxLength" => 32},
        "repository" => %{"type" => "string", "maxLength" => 140},
        "type" => %{"type" => "string", "maxLength" => 16},
        "path" => %{"type" => "string", "maxLength" => 500},
        "size" => %{"type" => "integer"},
        "truncated" => %{"type" => "boolean"},
        "content" => %{"type" => "string", "maxLength" => 65_536},
        "entries" => %{"type" => "array", "maxItems" => 200, "items" => entry_schema}
      },
      "required" => ["schema", "scope", "repository", "type"],
      "additionalProperties" => false
    }
  end
end
