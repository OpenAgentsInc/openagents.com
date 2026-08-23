defmodule OpenAgents.Tools.ConnectedRepositoryList do
  @moduledoc "Lists one directory in a connected Forge repository visible to the signed-in user."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ConnectedRepository, ExecutionResult, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.connected_repository_list.v1",
      name: "list_repository_directory",
      version: 1,
      description:
        "List files and directories at one path in a connected Forge repository the signed-in " <>
          "user can access. Pass an empty path for the root. List parent directories before " <>
          "choosing a file path.",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "repository.read",
      executor: %{
        id: "sarah.forge.browse",
        disclosure: "OpenAgents Forge with signed-in repository access"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{
        "privacy" => "signed_browser_owner",
        "residency" => "application_process",
        "consent" => "not_applicable"
      },
      module_metadata:
        Metadata.first_party("repository.read", "browser_conversation",
          effect: :read_only,
          privacy: "signed_browser_owner",
          residency: "application_process"
        ),
      timeout_ms: 15_000,
      maximum_input_bytes: 2_048,
      maximum_output_bytes: 262_144,
      implementation: __MODULE__,
      tags: ["forge", "repository", "directory", "list"]
    }
  end

  @impl true
  def execute(%{"repository" => repository, "path" => path, "ref" => ref}, context)
      when is_binary(repository) and is_binary(path) and is_binary(ref) do
    with {:ok, connected_repository} <- ConnectedRepository.resolve(context, repository),
         {:ok, result} <- ConnectedRepository.list(connected_repository, path, ref) do
      {:ok,
       %ExecutionResult{
         result: result,
         target_receipt_refs: ["forge-repository:#{connected_repository.id}"]
       }}
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_repository}

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "repository" => %{"type" => "string", "maxLength" => 201},
        "path" => %{"type" => "string", "maxLength" => 512},
        "ref" => %{"type" => "string", "maxLength" => 128}
      },
      "required" => ["repository", "path", "ref"],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    entry_schema = %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "maxLength" => 512},
        "path" => %{"type" => "string", "maxLength" => 512},
        "type" => %{"type" => "string", "maxLength" => 16},
        "size_bytes" => %{"type" => "integer"}
      },
      "required" => ["name", "path", "type", "size_bytes"],
      "additionalProperties" => false
    }

    %{
      "type" => "object",
      "properties" => %{
        "schema" => %{"type" => "string", "maxLength" => 64},
        "repository" => %{"type" => "string", "maxLength" => 201},
        "ref" => %{"type" => "string", "maxLength" => 128},
        "path" => %{"type" => "string", "maxLength" => 512},
        "entries" => %{"type" => "array", "maxItems" => 400, "items" => entry_schema},
        "count" => %{"type" => "integer"}
      },
      "required" => ["schema", "repository", "ref", "path", "entries", "count"],
      "additionalProperties" => false
    }
  end
end
