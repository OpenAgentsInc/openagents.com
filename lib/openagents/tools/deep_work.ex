defmodule OpenAgents.Tools.DeepWork do
  @moduledoc """
  First-party `deep_work.v1`: starts a durable delegated deep-work job.

  The call returns immediately with a job reference so the current turn or
  voice response can acknowledge in one sentence; the multi-step work runs in
  a budgeted, recoverable server-side loop (`OpenAgents.Work.JobServer`) and its
  bounded report lands back in the conversation as a durable message.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Tool}
  alias OpenAgents.Work
  alias OpenAgents.Work.Job

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.deep_work.v1",
      name: "deep_work",
      version: 1,
      description:
        "Delegates a multi-step goal — research, lookaround, or a long coding " <>
          "delegation to a paired computer that would outlast a single turn — to " <>
          "a durable background job that uses the same governed tools (including " <>
          "computer_agent) and reports back into this conversation when done. " <>
          "Prefer this over calling computer_agent directly when the coding task " <>
          "is large or multi-step. Returns immediately with a job reference; " <>
          "acknowledge briefly and do not wait for the result",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "work.delegate",
      executor: %{id: "sarah.work.jobs", disclosure: "Sarah durable work jobs"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/sarah"],
      policy_facets: %{
        "privacy" => "browser_conversation",
        "residency" => "application_postgres",
        "delegation" => "bounded_server_side_job"
      },
      module_metadata:
        Metadata.first_party("work.delegate", "browser_conversation",
          effect: :read_only,
          privacy: "browser_conversation",
          residency: "application_postgres"
        ),
      timeout_ms: 5_000,
      maximum_input_bytes: 8_192,
      maximum_output_bytes: 4_096,
      implementation: __MODULE__,
      tags: ~w(delegation background job durable research coding fix)
    }
  end

  @impl true
  def execute(arguments, context) do
    goal = arguments |> Map.fetch!("goal") |> String.trim()
    context_hint = normalize_hint(Map.get(arguments, "context_hint"))

    with :ok <- validate_goal(goal),
         :ok <- validate_context(context) do
      attributes = %{
        conversation_id: context.conversation_id,
        owner_visitor_id: context.owner_visitor_id,
        surface: context.surface,
        goal: goal,
        context_hint: context_hint
      }

      case Work.start_job(attributes) do
        {:ok, job} ->
          {:ok,
           %ExecutionResult{
             result: %{
               "schema" => "sarah.deep_work_started.v1",
               "job_ref" => "work-job:#{job.id}",
               "status" => "started",
               "goal" => goal
             },
             target_receipt_refs: ["work-job:#{job.id}"]
           }}

        {:error, _reason} ->
          {:error, :work_job_start_failed}
      end
    end
  end

  defp validate_goal(""), do: {:error, :invalid_work_goal}

  defp validate_goal(goal) when byte_size(goal) <= 2_000, do: :ok
  defp validate_goal(_goal), do: {:error, :invalid_work_goal}

  defp validate_context(%{conversation_id: conversation_id, owner_visitor_id: owner_visitor_id})
       when is_binary(conversation_id) and is_binary(owner_visitor_id),
       do: :ok

  defp validate_context(_context), do: {:error, :scope_refused}

  defp normalize_hint(nil), do: nil
  defp normalize_hint(""), do: nil

  defp normalize_hint(hint) when is_binary(hint) do
    case String.trim(hint) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_hint(_hint), do: nil

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "goal" => %{
          "type" => "string",
          "maxLength" => Job.maximum_goal_bytes(),
          "description" =>
            "The complete delegated goal, self-contained enough to run without this conversation"
        },
        "context_hint" => %{
          "type" => "string",
          "maxLength" => Job.maximum_context_hint_bytes(),
          "description" => "Optional extra context the job should know; empty string for none"
        }
      },
      "required" => ["goal"],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "schema" => %{"type" => "string", "maxLength" => 64},
        "job_ref" => %{"type" => "string", "maxLength" => 128},
        "status" => %{"type" => "string", "maxLength" => 16},
        "goal" => %{"type" => "string", "maxLength" => Job.maximum_goal_bytes()}
      },
      "required" => ["schema", "job_ref", "status", "goal"],
      "additionalProperties" => false
    }
  end
end
