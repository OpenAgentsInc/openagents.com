defmodule OpenAgents.Tools.GitHubRepoList do
  @moduledoc "Lists GitHub repositories the signed-in user can access, using their OAuth token."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.GitHub
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, GitHubContext, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.github_repo_list.v1",
      name: "github_repo_list",
      version: 1,
      description:
        "Lists GitHub repositories the signed-in user owns or collaborates on, most recently " <>
          "pushed first. Use this whenever the user asks about their repos or projects on " <>
          "GitHub. Pass first as the number of repositories to return (1-50).",
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
      maximum_input_bytes: 1_024,
      maximum_output_bytes: 65_536,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"first" => first}, context) when is_integer(first) and first in 1..50 do
    with {:ok, token, user} <- GitHubContext.resolve(context),
         {:ok, repositories} <- GitHub.list_repositories(token, first: first) do
      {:ok,
       %ExecutionResult{
         result: %{
           "schema" => "sarah.github_repo_list_result.v1",
           "scope" => "signed_github_user",
           "github_login" => user.github_login,
           "status" => if(repositories == [], do: "empty", else: "matches"),
           "repositories" => repositories
         },
         target_receipt_refs: Enum.map(repositories, &"github-repo:#{&1["full_name"]}")
       }}
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_result_limit}

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "first" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
      },
      "required" => ["first"],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    repository_schema = %{
      "type" => "object",
      "properties" => %{
        "full_name" => string(140),
        "description" => string(300),
        "private" => %{"type" => "boolean"},
        "default_branch" => string(100),
        "language" => string(60),
        "pushed_at" => string(32)
      },
      "required" => [
        "full_name",
        "description",
        "private",
        "default_branch",
        "language",
        "pushed_at"
      ],
      "additionalProperties" => false
    }

    %{
      "type" => "object",
      "properties" => %{
        "schema" => string(64),
        "scope" => string(32),
        "github_login" => string(64),
        "status" => string(16),
        "repositories" => %{"type" => "array", "maxItems" => 50, "items" => repository_schema}
      },
      "required" => ["schema", "scope", "github_login", "status", "repositories"],
      "additionalProperties" => false
    }
  end

  defp string(maximum), do: %{"type" => "string", "maxLength" => maximum}
end
