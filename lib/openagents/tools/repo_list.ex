defmodule OpenAgents.Tools.RepoList do
  @moduledoc "Lists a directory of Sarah's own source tree, bounded."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Repository, Tool}

  @max_entries 500
  @skip ~w(.git _build deps node_modules)

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.repo_list.v1",
      name: "repo_list",
      version: 1,
      description:
        "Lists files and directories in Sarah's own source tree. Pass path relative to the " <>
          "repository root (default: the root). from selects \"image\" (running source, " <>
          "default) or \"workspace\" (this job's clone).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "maxLength" => 512},
          "from" => %{"type" => "string", "enum" => ["image", "workspace"]}
        },
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "repository.read",
      executor: %{
        id: "sarah.repository.self",
        disclosure: "Sarah's own runtime, listing her running source"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/sarah"],
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
      maximum_output_bytes: 65_536,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(arguments, context) when is_map(arguments) do
    path = Map.get(arguments, "path", ".")

    with {:ok, root} <- Repository.tool_root(Map.get(arguments, "from", "image"), context),
         {:ok, resolved} <- Repository.safe_path(root, path) do
      if File.dir?(resolved) do
        entries =
          resolved
          |> File.ls!()
          |> Enum.sort()
          |> Enum.reject(&(&1 in @skip))
          |> Enum.take(@max_entries)
          |> Enum.map(fn name ->
            full = Path.join(resolved, name)

            %{
              "name" => name,
              "type" => if(File.dir?(full), do: "directory", else: "file")
            }
          end)

        {:ok,
         %ExecutionResult{
           result: %{
             "schema" => "sarah.repo_list_result.v1",
             "path" => path,
             "entries" => entries
           }
         }}
      else
        {:error, :repository_file_not_found}
      end
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_repository_path}
end
