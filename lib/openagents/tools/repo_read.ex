defmodule OpenAgents.Tools.RepoRead do
  @moduledoc "Reads one file from OpenAgents source (baked image tree or the job's clone)."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Repository, Tool}

  @max_bytes 200_000

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.repo_read.v1",
      name: "repo_read",
      version: 1,
      description:
        "Reads one file from OpenAgents source code. Pass path relative to the repository " <>
          "root. from selects the tree: \"image\" (default) reads the source of the code " <>
          "currently running; \"workspace\" reads this job's editable clone.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "maxLength" => 512},
          "from" => %{"type" => "string", "enum" => ["image", "workspace"]}
        },
        "required" => ["path"],
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "repository.read",
      executor: %{
        id: "sarah.repository.self",
        disclosure: "the OpenAgents runtime, reading her running source"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{
        "privacy" => "browser_conversation",
        "residency" => "host",
        "consent" => "not_applicable"
      },
      module_metadata:
        Metadata.first_party("repository.read", "browser_conversation",
          effect: :read_only,
          privacy: "browser_conversation",
          residency: "host",
          surfaces: ["text"]
        ),
      timeout_ms: 10_000,
      maximum_input_bytes: 2_048,
      maximum_output_bytes: 262_144,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"path" => path} = arguments, context) when is_binary(path) do
    with {:ok, root} <- Repository.tool_root(Map.get(arguments, "from", "image"), context),
         {:ok, resolved} <- Repository.safe_path(root, path) do
      cond do
        not File.regular?(resolved) ->
          {:error, :repository_file_not_found}

        true ->
          content = File.read!(resolved)
          truncated = byte_size(content) > @max_bytes

          {:ok,
           %ExecutionResult{
             result: %{
               "schema" => "sarah.repo_read_result.v1",
               "path" => path,
               "from" => Map.get(arguments, "from", "image"),
               "content" => binary_slice(content, 0, @max_bytes),
               "bytes" => byte_size(content),
               "truncated" => truncated
             }
           }}
      end
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_repository_path}
end
