defmodule OpenAgents.Tools.ModuleDiscover do
  @moduledoc "Bounded discovery over the exact module registry captured by this turn."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.{Discovery, Metadata}
  alias OpenAgents.Tools.{ExecutionResult, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.module_discover.v1",
      name: "module_discover",
      version: 1,
      description:
        "Searches Sarah's tools by relevance (semantic + lexical over each " <>
          "tool's description), by `tags`, or a combination, without granting " <>
          "execution. The system already selects the tools most relevant to the " <>
          "conversation each turn, so use this only to look further afield.",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "module.discover",
      executor: %{id: "sarah.module.discovery", disclosure: "Sarah module discovery"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/sarah"],
      policy_facets: %{
        "privacy" => "public_catalog_metadata_only",
        "residency" => "application_process"
      },
      module_metadata:
        Metadata.first_party("module.discover", "browser_conversation",
          effect: :read_only,
          privacy: "public_catalog_metadata_only",
          residency: "application_process"
        ),
      timeout_ms: 1_000,
      maximum_input_bytes: 2_048,
      maximum_output_bytes: 32_768,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(arguments, %{module_registry_snapshot: snapshot}) when not is_nil(snapshot) do
    with {:ok, result} <- Discovery.search(snapshot, arguments) do
      references =
        Enum.map(result["matches"], fn match ->
          "module:#{match["module_id"]}:#{match["version"]}:#{match["artifact_digest"]}"
        end)

      {:ok, %ExecutionResult{result: result, target_receipt_refs: references}}
    end
  end

  def execute(_arguments, _context), do: {:error, :module_registry_unavailable}

  defp input_schema do
    string = %{"type" => "string", "maxLength" => 128}

    %{
      "type" => "object",
      "properties" => %{
        "query" => string,
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string", "maxLength" => 64},
          "maxItems" => 16
        },
        "capability" => string,
        "side_effect" => string,
        "data_scope" => string,
        "cost" => string,
        "quality" => string,
        "jurisdiction" => string,
        "publisher" => string,
        "compatibility" => %{"type" => "integer"},
        "include_deprecated" => %{"type" => "boolean"},
        "first" => %{"type" => "integer"}
      },
      "additionalProperties" => false
    }
  end

  defp output_schema do
    string = %{"type" => "string", "maxLength" => 512}

    projection = %{
      "type" => "object",
      "properties" => %{
        "module_id" => string,
        "version" => %{"type" => "integer"},
        "artifact_digest" => string,
        "registry_digest" => string,
        "state" => string,
        "side_effect" => string,
        "approval_class" => string,
        "capability_scopes" => %{"type" => "array", "maxItems" => 32, "items" => string},
        "data_scopes" => %{"type" => "array", "maxItems" => 32, "items" => string},
        "facets" => %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
        "publisher" => string,
        "compatibility" => %{
          "type" => "object",
          "properties" => %{
            "runtime_min" => %{"type" => "integer"},
            "runtime_max" => %{"type" => "integer"}
          },
          "required" => ["runtime_min", "runtime_max"],
          "additionalProperties" => false
        },
        "deprecation" => %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => true
        },
        "attribution_required" => %{"type" => "boolean"}
      },
      "required" => [
        "module_id",
        "version",
        "artifact_digest",
        "registry_digest",
        "state",
        "side_effect",
        "approval_class",
        "capability_scopes",
        "data_scopes",
        "facets",
        "publisher",
        "compatibility",
        "attribution_required"
      ],
      "additionalProperties" => false
    }

    %{
      "type" => "object",
      "properties" => %{
        "schema" => string,
        "registry_digest" => string,
        "matches" => %{"type" => "array", "maxItems" => 20, "items" => projection},
        "truncated" => %{"type" => "boolean"}
      },
      "required" => ["schema", "registry_digest", "matches", "truncated"],
      "additionalProperties" => false
    }
  end
end
