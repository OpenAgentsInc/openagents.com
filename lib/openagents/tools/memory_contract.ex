defmodule OpenAgents.Tools.MemoryContract do
  @moduledoc false

  alias OpenAgents.Tools.Tool
  alias OpenAgents.Modules.Metadata

  def tool(module, name, description, input_schema, output_schema, effect, authority, opts \\ []) do
    %Tool{
      module_id: "sarah.tool.#{name}.v1",
      name: name,
      version: 1,
      description: description,
      input_schema: input_schema,
      output_schema: output_schema,
      side_effect: effect,
      required_scope: "browser_conversation",
      required_authority: authority,
      executor: %{id: "sarah.postgres.profile_memory", disclosure: "Sarah profile memory"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/sarah", "OpenResponses/2026-04-24"],
      policy_facets: %{
        "privacy" => "signed_browser_owner",
        "residency" => "application_postgres",
        "consent" => if(effect == :read_only, do: "not_applicable", else: "host_verified")
      },
      module_metadata:
        Metadata.first_party(authority, "browser_conversation",
          effect: effect,
          privacy: "signed_browser_owner",
          residency: "application_postgres"
        ),
      timeout_ms: 5_000,
      maximum_input_bytes: Keyword.get(opts, :maximum_input_bytes, 2_048),
      maximum_output_bytes: 32_768,
      implementation: module
    }
  end

  def memory_output(record) do
    %{
      "id" => record.id,
      "category" => record.category,
      "claim" => record.claim,
      "generation" => record.generation,
      "source_refs" => Enum.map(record.sources, &"message:#{&1.message_id}")
    }
  end

  def memory_schema do
    %{
      "type" => "object",
      "properties" => %{
        "id" => string(64),
        "category" => string(32),
        "claim" => string(500),
        "generation" => %{"type" => "integer"},
        "source_refs" => %{"type" => "array", "maxItems" => 8, "items" => string(64)}
      },
      "required" => ["id", "category", "claim", "generation", "source_refs"],
      "additionalProperties" => false
    }
  end

  def receipt(operation, disposition, message_id, records) do
    %{
      "schema" => "sarah.memory_operation_receipt.v1",
      "operation" => operation,
      "disposition" => disposition,
      "scope" => "this_browser",
      "consent_source_ref" => "message:#{message_id}",
      "reversible" => true,
      "record_refs" => Enum.map(records, &record_ref/1)
    }
  end

  def receipt_schema do
    %{
      "type" => "object",
      "properties" => %{
        "schema" => string(64),
        "operation" => string(32),
        "disposition" => string(32),
        "scope" => string(32),
        "consent_source_ref" => string(64),
        "reversible" => %{"type" => "boolean"},
        "record_refs" => %{"type" => "array", "maxItems" => 200, "items" => string(128)}
      },
      "required" => [
        "schema",
        "operation",
        "disposition",
        "scope",
        "consent_source_ref",
        "reversible",
        "record_refs"
      ],
      "additionalProperties" => false
    }
  end

  def record_ref(record), do: "profile-memory:v1:#{record.id}:#{record.generation}"
  def string(maximum), do: %{"type" => "string", "maxLength" => maximum}

  @doc "Maps any model-supplied category onto the closed record category set."
  def normalize_category(category) when is_binary(category) do
    normalized = category |> String.trim() |> String.downcase()

    if normalized in OpenAgents.ProfileMemory.Record.categories(),
      do: normalized,
      else: "other"
  end
end
