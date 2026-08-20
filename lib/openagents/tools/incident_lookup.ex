defmodule OpenAgents.Tools.IncidentLookup do
  @moduledoc """
  First-party `incident_lookup.v1`: lets Sarah read durable failure evidence
  so she can answer "why did that fail?" without guessing.

  Read-only and owner-scoped. Returns recent incidents *and* recent work-job
  reports for this conversation. A job that just timed out is the cause of
  "why did that fail?"; an incident hours earlier is previous context.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Conversations.Conversation
  alias OpenAgents.Incidents
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, OwnerContext, Tool}
  alias OpenAgents.Work

  @maximum_listed 20
  @maximum_jobs 5
  @maximum_report_excerpt 500

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.incident_lookup.v1",
      name: "incident_lookup",
      version: 1,
      description:
        "Reads durable failure evidence for the signed-in owner so you can " <>
          "explain why something failed instead of guessing. Use it whenever " <>
          "the person asks why a turn, delegation, voice session, or job " <>
          "failed. Returns recent incidents AND recent work-job reports. " <>
          "Prefer jobs[] when it is more recent than incidents[] — a just-" <>
          "failed delegation is the cause; an incident hours earlier is " <>
          "previous context, not the cause. Honor primary. scope " <>
          "'conversation' (default) limits to this conversation; 'owner' " <>
          "spans recent incidents. Optional correlation_ref filters to one " <>
          "job or turn id.",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "conversation.read",
      executor: %{
        id: "sarah.incidents",
        disclosure: "Durable failure records for the signed-in owner"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{
        "privacy" => "signed_browser_owner",
        "residency" => "application_process",
        "consent" => "not_applicable"
      },
      module_metadata:
        Metadata.first_party("conversation.read", "browser_conversation",
          effect: :read_only,
          privacy: "signed_browser_owner",
          residency: "application_process"
        ),
      timeout_ms: 10_000,
      maximum_input_bytes: 256,
      maximum_output_bytes: 32_768,
      implementation: __MODULE__,
      tags: ~w(incident error failure diagnosis debug analyze why)
    }
  end

  @impl true
  def execute(arguments, context) do
    with {:ok, user} <- OwnerContext.resolve(context) do
      scope = if arguments["scope"] == "owner", do: :owner, else: :conversation
      limit = clamp(arguments["limit"])
      correlation_ref = normalize_ref(arguments["correlation_ref"])

      opts =
        [limit: limit] ++
          if(scope == :conversation and is_binary(context.conversation_id),
            do: [conversation_id: context.conversation_id],
            else: []
          )

      incidents =
        user.id
        |> Incidents.list_recent(opts)
        |> Enum.filter(&matches_ref?(&1.correlation_ref, correlation_ref))

      listed = Enum.map(incidents, &summarize(&1, user.id))

      jobs =
        context.conversation_id
        |> recent_jobs()
        |> Enum.filter(&matches_ref?(&1.id, correlation_ref))
        |> Enum.map(&summarize_job/1)

      primary = primary_source(listed, jobs)

      {:ok,
       %ExecutionResult{
         result: %{
           "schema" => "sarah.incident_lookup_result.v1",
           "scope" => Atom.to_string(scope),
           "status" => status(listed, jobs),
           "primary" => primary,
           "guidance" => guidance(primary),
           "incidents" => listed,
           "jobs" => jobs
         },
         target_receipt_refs: []
       }}
    end
  end

  defp summarize(incident, owner_user_id) do
    %{
      "id" => incident.id,
      "code" => incident.code,
      "severity" => incident.severity,
      "origin" => incident.origin,
      "surface" => incident.surface,
      "summary" => incident.summary || "",
      "status" => incident.status,
      "correlation_ref" => incident.correlation_ref || "",
      "occurred_at" => DateTime.to_iso8601(incident.inserted_at),
      "recurrence_count" => Incidents.recurrence_count(owner_user_id, incident.code),
      "being_fixed" => not is_nil(incident.fixer_job_id)
    }
  end

  defp recent_jobs(conversation_id) when is_binary(conversation_id) do
    Work.recent_jobs(%Conversation{id: conversation_id}, @maximum_jobs)
    |> Enum.filter(&(&1.status in OpenAgents.Work.Job.terminal_statuses()))
  end

  defp recent_jobs(_conversation_id), do: []

  defp summarize_job(job) do
    %{
      "id" => job.id,
      "kind" => job.kind || "deep_work",
      "status" => job.status,
      "error_code" => job.error_code || "",
      "goal" => job.goal || "",
      "report_excerpt" => excerpt(job.report),
      "completed_at" => iso8601(job.completed_at || job.updated_at)
    }
  end

  defp excerpt(report) when is_binary(report) and report != "",
    do: String.slice(String.trim(report), 0, @maximum_report_excerpt)

  defp excerpt(_report), do: ""

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_missing), do: ""

  defp primary_source([], []), do: "none"
  defp primary_source([], _jobs), do: "job"
  defp primary_source(_incidents, []), do: "incident"

  defp primary_source([incident | _rest], [job | _jobs]) do
    incident_at = parse_iso(incident["occurred_at"])
    job_at = parse_iso(job["completed_at"])

    cond do
      is_nil(incident_at) -> "job"
      is_nil(job_at) -> "incident"
      DateTime.compare(job_at, incident_at) != :lt -> "job"
      true -> "incident"
    end
  end

  defp parse_iso(value) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> nil
    end
  end

  defp parse_iso(_value), do: nil

  defp status([], []), do: "none"
  defp status(_incidents, _jobs), do: "matches"

  defp guidance("job"),
    do:
      "Explain the most recent jobs[] entry. Older incidents[] are previous context, not this failure."

  defp guidance("incident"),
    do: "Explain the most recent incidents[] entry. No newer job report is on record."

  defp guidance(_none),
    do: "No incident or job report is on record for this question."

  defp normalize_ref(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: String.slice(trimmed, 0, 128)
  end

  defp normalize_ref(_value), do: nil

  defp matches_ref?(_value, nil), do: true
  defp matches_ref?(value, ref) when is_binary(value), do: value == ref
  defp matches_ref?(_value, _ref), do: false

  defp clamp(value) when is_integer(value), do: value |> min(@maximum_listed) |> max(1)
  defp clamp(_value), do: @maximum_listed

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "scope" => %{"type" => "string", "enum" => ["conversation", "owner"]},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => @maximum_listed},
        "correlation_ref" => %{"type" => "string", "maxLength" => 128}
      },
      "required" => [],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "schema" => %{"type" => "string", "maxLength" => 64},
        "scope" => %{"type" => "string", "maxLength" => 32},
        "status" => %{"type" => "string", "maxLength" => 32},
        "primary" => %{"type" => "string", "maxLength" => 16},
        "guidance" => %{"type" => "string", "maxLength" => 240},
        "jobs" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string"},
              "kind" => %{"type" => "string"},
              "status" => %{"type" => "string"},
              "error_code" => %{"type" => "string"},
              "goal" => %{"type" => "string"},
              "report_excerpt" => %{"type" => "string"},
              "completed_at" => %{"type" => "string"}
            },
            "required" => [
              "id",
              "kind",
              "status",
              "error_code",
              "goal",
              "report_excerpt",
              "completed_at"
            ],
            "additionalProperties" => false
          }
        },
        "incidents" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string"},
              "code" => %{"type" => "string"},
              "severity" => %{"type" => "string"},
              "origin" => %{"type" => "string"},
              "surface" => %{"type" => "string"},
              "summary" => %{"type" => "string"},
              "status" => %{"type" => "string"},
              "correlation_ref" => %{"type" => "string"},
              "occurred_at" => %{"type" => "string"},
              "recurrence_count" => %{"type" => "integer"},
              "being_fixed" => %{"type" => "boolean"}
            },
            "required" => [
              "id",
              "code",
              "severity",
              "origin",
              "surface",
              "summary",
              "status",
              "correlation_ref",
              "occurred_at",
              "recurrence_count",
              "being_fixed"
            ],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["schema", "scope", "status", "primary", "guidance", "incidents", "jobs"],
      "additionalProperties" => false
    }
  end
end
