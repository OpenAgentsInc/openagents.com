defmodule OpenAgents.Tools.ConversationSearch do
  @moduledoc "First-party read-only recall discovery within one frozen conversation snapshot."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, RecallContext, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.conversation_search.v1",
      name: "conversation_search",
      version: 1,
      description:
        "Finds candidate messages and durable tool activity (completed tool steps from text " <>
          "and voice, matched on tool name, status, and bounded result text) in the current " <>
          "conversation before relying on older context",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "conversation.read",
      executor: %{
        id: "sarah.postgres.recall",
        disclosure: "Sarah conversation recall"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/sarah"],
      policy_facets: %{
        "privacy" => "browser_conversation",
        "residency" => "application_postgres",
        "ranking" => "configured_lexical_or_hybrid"
      },
      module_metadata:
        Metadata.first_party("conversation.read", "browser_conversation",
          effect: :read_only,
          privacy: "browser_conversation",
          residency: "application_postgres"
        ),
      timeout_ms: 5_000,
      maximum_input_bytes: 1_024,
      maximum_output_bytes: 16_384,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(arguments, context) do
    with {:ok, conversation, snapshot} <- RecallContext.resolve(context),
         {:ok, options} <- search_options(arguments),
         {:ok, page} <-
           recall_backend().search_page(conversation, snapshot, arguments["query"], options) do
      matches = Enum.map(page.matches, &match_output/1)

      {:ok,
       %ExecutionResult{
         result: %{
           "schema" => "sarah.conversation_search_result.v1",
           "scope" => "browser_conversation",
           "snapshot_ref" => context.memory_snapshot_ref,
           "status" => if(matches == [], do: "empty", else: "matches"),
           "ranking" => page.strategy,
           "semantic_degraded" => page.semantic_degraded,
           "semantic_reason" => page.semantic_reason || "none",
           "matches" => matches,
           "truncated" => page.truncated
         },
         target_receipt_refs: Enum.map(matches, & &1["source_ref"])
       }}
    end
  end

  defp recall_backend,
    do: Application.fetch_env!(:sarah, :recall_search_backend)

  defp search_options(arguments) do
    with {:ok, before} <- parse_time(Map.get(arguments, "before")),
         {:ok, after_time} <- parse_time(Map.get(arguments, "after")) do
      {:ok,
       [
         first: Map.get(arguments, "first", 5),
         before: before,
         after: after_time
       ]}
    end
  end

  defp parse_time(nil), do: {:ok, nil}

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, 0} -> {:ok, timestamp}
      _invalid -> {:error, :invalid_time_bound}
    end
  end

  defp parse_time(_value), do: {:error, :invalid_time_bound}

  defp match_output(match) do
    %{
      "source_ref" => match.source_ref,
      "role" => match.role,
      "observed_at" => DateTime.to_iso8601(match.observed_at),
      "excerpt" => match.excerpt,
      "score" => match.score,
      "rank" => match.rank,
      "truncated" => match.truncated
    }
  end

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "maxLength" => 512},
        "before" => %{"type" => "string", "maxLength" => 64},
        "after" => %{"type" => "string", "maxLength" => 64},
        "first" => %{"type" => "integer"}
      },
      "required" => ["query"],
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
        "status" => %{"type" => "string", "maxLength" => 16},
        "ranking" => %{"type" => "string", "maxLength" => 32},
        "semantic_degraded" => %{"type" => "boolean"},
        "semantic_reason" => %{"type" => "string", "maxLength" => 64},
        "matches" => %{
          "type" => "array",
          "maxItems" => 10,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "source_ref" => %{"type" => "string", "maxLength" => 64},
              "role" => %{"type" => "string", "maxLength" => 16},
              "observed_at" => %{"type" => "string", "maxLength" => 40},
              "excerpt" => %{"type" => "string", "maxLength" => 800},
              "score" => %{"type" => "number"},
              "rank" => %{"type" => "integer"},
              "truncated" => %{"type" => "boolean"}
            },
            "required" => [
              "source_ref",
              "role",
              "observed_at",
              "excerpt",
              "score",
              "rank",
              "truncated"
            ],
            "additionalProperties" => false
          }
        },
        "truncated" => %{"type" => "boolean"}
      },
      "required" => [
        "schema",
        "scope",
        "snapshot_ref",
        "status",
        "ranking",
        "semantic_degraded",
        "semantic_reason",
        "matches",
        "truncated"
      ],
      "additionalProperties" => false
    }
  end
end
