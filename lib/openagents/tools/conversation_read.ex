defmodule OpenAgents.Tools.ConversationRead do
  @moduledoc "First-party exact bounded context read within one frozen conversation snapshot."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Memory.{Evidence, LexicalRecall}
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, RecallContext, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.conversation_read.v1",
      name: "conversation_read",
      version: 1,
      description:
        "Reads exact bounded conversation context around a source returned by " <>
          "conversation_search: a message ref, or a turn-tool-step/voice-tool-step ref " <>
          "resolved into the durable tool step plus its neighboring messages",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "conversation.read",
      executor: %{
        id: "sarah.postgres.conversation_read",
        disclosure: "Sarah conversation recall"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/sarah"],
      policy_facets: %{
        "privacy" => "browser_conversation",
        "residency" => "application_postgres"
      },
      module_metadata:
        Metadata.first_party("conversation.read", "browser_conversation",
          effect: :read_only,
          privacy: "browser_conversation",
          residency: "application_postgres"
        ),
      timeout_ms: 5_000,
      maximum_input_bytes: 1_024,
      maximum_output_bytes: 65_536,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(arguments, context) do
    with {:ok, conversation, snapshot} <- RecallContext.resolve(context),
         {:ok, neighborhood} <-
           LexicalRecall.read(conversation, snapshot, arguments["source_ref"],
             before: Map.get(arguments, "before", 2),
             after: Map.get(arguments, "after", 2)
           ),
         {:ok, evidence} <-
           Evidence.build(conversation, snapshot, neighborhood.source_ref,
             relevance: "Exact source selected for bounded conversation context."
           ) do
      messages = Enum.map(neighborhood.messages, &message_output/1)

      result = %{
        "schema" => "sarah.conversation_read_result.v1",
        "scope" => "browser_conversation",
        "snapshot_ref" => context.memory_snapshot_ref,
        "source_ref" => neighborhood.source_ref,
        "evidence" => Evidence.to_output(evidence),
        "messages" => messages,
        "before_truncated" => neighborhood.before_truncated,
        "after_truncated" => neighborhood.after_truncated
      }

      {:ok,
       %ExecutionResult{
         result: maybe_put_tool_step(result, neighborhood.source_step),
         target_receipt_refs: Enum.map(messages, & &1["source_ref"])
       }}
    end
  end

  defp message_output(message) do
    %{
      "source_ref" => message.source_ref,
      "role" => message.role,
      "observed_at" => DateTime.to_iso8601(message.observed_at),
      "content" => message.content
    }
  end

  defp maybe_put_tool_step(result, nil), do: result

  defp maybe_put_tool_step(result, step) do
    tool_step =
      %{
        "source_ref" => step.source_ref,
        "surface" => step.surface,
        "tool_name" => step.tool_name,
        "status" => step.status,
        "executor_disclosure" => step.executor_disclosure,
        "completed_at" => DateTime.to_iso8601(step.completed_at),
        "truncated" => step.truncated
      }
      |> maybe_put("argument_digest", step.argument_digest)
      |> maybe_put("executor_id", step.executor_id)
      |> maybe_put("requested_at", step.requested_at && DateTime.to_iso8601(step.requested_at))
      |> maybe_put("result", step.result)
      |> maybe_put("error", step.error)

    Map.put(result, "tool_step", tool_step)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "source_ref" => %{"type" => "string", "maxLength" => 64},
        "before" => %{"type" => "integer"},
        "after" => %{"type" => "integer"}
      },
      "required" => ["source_ref"],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "schema" => %{"type" => "string", "maxLength" => 64},
        "scope" => %{"type" => "string", "maxLength" => 64},
        "snapshot_ref" => %{"type" => "string", "maxLength" => 64},
        "source_ref" => %{"type" => "string", "maxLength" => 64},
        "evidence" => evidence_schema(),
        "messages" => %{
          "type" => "array",
          "maxItems" => 7,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "source_ref" => %{"type" => "string", "maxLength" => 64},
              "role" => %{"type" => "string", "maxLength" => 16},
              "observed_at" => %{"type" => "string", "maxLength" => 40},
              "content" => %{"type" => "string", "maxLength" => 8_000}
            },
            "required" => ["source_ref", "role", "observed_at", "content"],
            "additionalProperties" => false
          }
        },
        "before_truncated" => %{"type" => "boolean"},
        "after_truncated" => %{"type" => "boolean"},
        "tool_step" => tool_step_schema()
      },
      "required" => [
        "schema",
        "scope",
        "snapshot_ref",
        "source_ref",
        "evidence",
        "messages",
        "before_truncated",
        "after_truncated"
      ],
      "additionalProperties" => false
    }
  end

  defp tool_step_schema do
    %{
      "type" => "object",
      "properties" => %{
        "source_ref" => %{"type" => "string", "maxLength" => 64},
        "surface" => %{"type" => "string", "maxLength" => 16},
        "tool_name" => %{"type" => "string", "maxLength" => 128},
        "status" => %{"type" => "string", "maxLength" => 16},
        "argument_digest" => %{"type" => "string", "maxLength" => 64},
        "executor_id" => %{"type" => "string", "maxLength" => 128},
        "executor_disclosure" => %{"type" => "string", "maxLength" => 256},
        "requested_at" => %{"type" => "string", "maxLength" => 40},
        "completed_at" => %{"type" => "string", "maxLength" => 40},
        "result" => %{"type" => "string", "maxLength" => 4_000},
        "error" => %{"type" => "string", "maxLength" => 4_000},
        "truncated" => %{"type" => "boolean"}
      },
      "required" => [
        "source_ref",
        "surface",
        "tool_name",
        "status",
        "executor_disclosure",
        "completed_at",
        "truncated"
      ],
      "additionalProperties" => false
    }
  end

  defp evidence_schema do
    %{
      "type" => "object",
      "properties" => %{
        "schema" => %{"type" => "string", "maxLength" => 64},
        "source_ref" => %{"type" => "string", "maxLength" => 64},
        "source_scope" => %{
          "type" => "object",
          "properties" => %{
            "kind" => %{"type" => "string", "maxLength" => 64},
            "ref" => %{"type" => "string", "maxLength" => 64},
            "snapshot_ref" => %{"type" => "string", "maxLength" => 64}
          },
          "required" => ["kind", "ref", "snapshot_ref"],
          "additionalProperties" => false
        },
        "observed_at" => %{"type" => "string", "maxLength" => 40},
        "recalled_at" => %{"type" => "string", "maxLength" => 40},
        "claim" => %{"type" => "string", "maxLength" => 800},
        "relevance" => %{"type" => "string", "maxLength" => 500},
        "classification" => %{"type" => "string", "maxLength" => 16},
        "corroborates" => %{
          "type" => "array",
          "maxItems" => 8,
          "items" => %{"type" => "string", "maxLength" => 64}
        },
        "conflicts_with" => %{
          "type" => "array",
          "maxItems" => 8,
          "items" => %{"type" => "string", "maxLength" => 64}
        }
      },
      "required" => [
        "schema",
        "source_ref",
        "source_scope",
        "observed_at",
        "recalled_at",
        "claim",
        "relevance",
        "classification",
        "corroborates",
        "conflicts_with"
      ],
      "additionalProperties" => false
    }
  end
end
