defmodule OpenAgents.Tools.ScvDeploy do
  @moduledoc """
  First-party `scv_deploy.v1`: deploys an OpenCode SCV on OpenAgents capacity.

  Every other way Sarah runs code ends on a computer the person owns. This one
  ends on ours: a bounded OpenCode run against an exact revision of a
  repository in our own forge, under the read-only permission profile, on the
  admitted model. Because it spends our capacity rather than the caller's, it
  is operator-only, and the refusal lives in
  `OpenAgents.SCV.Deployments.start/2` — the code that starts the run — not in
  this tool's description.

  The call returns immediately with a job reference. The SCV works in a durable
  background job and its bounded report lands back in the conversation as a
  message when it ends.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.SCV.Deployments
  alias OpenAgents.Tools.{ExecutionResult, OwnerContext, Tool}
  alias OpenAgents.Work.Scv

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.scv_deploy.v1",
      name: "scv_deploy",
      version: 1,
      description:
        "Deploys an SCV — a bounded OpenCode coding agent that runs on OpenAgents " <>
          "capacity rather than on anyone's own computer — against a repository in " <>
          "the OpenAgents forge. OPERATOR ONLY: a request from anyone who is not an " <>
          "OpenAgents operator is refused. Name the repository as owner/name; it runs " <>
          "read-only against the current head of its default branch. Returns " <>
          "immediately with a job reference: acknowledge briefly, do NOT wait, and " <>
          "the SCV's report posts back into this conversation when it finishes. " <>
          "Prefer computer_agent when the person wants work on their own computer.",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :external_effect,
      required_scope: "browser_conversation",
      required_authority: "scv.deploy",
      executor: %{
        id: "sarah.scv.opencode",
        disclosure: "A bounded OpenCode SCV running on OpenAgents capacity"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com", "anomalyco/opencode"],
      policy_facets: %{
        "privacy" => "signed_browser_owner",
        "residency" => "openagents_capacity",
        "consent" => "operator_authority"
      },
      module_metadata:
        Metadata.first_party("scv.deploy", "browser_conversation",
          effect: :external_effect,
          approval_class: "explicit_operator_approval",
          privacy: "signed_browser_owner",
          residency: "openagents_capacity"
        ),
      timeout_ms: 15_000,
      maximum_input_bytes: 4_096,
      maximum_output_bytes: 4_096,
      implementation: __MODULE__,
      tags: ~w(scv deploy opencode coding agent capacity operator admin)
    }
  end

  @impl true
  def execute(%{"repository" => repository, "objective" => objective}, context)
      when is_binary(repository) and is_binary(objective) do
    # The owner behind this conversation is resolved from the application's own
    # records, never from an argument the model supplied.
    with {:ok, user} <- OwnerContext.resolve(context) do
      case Deployments.start(user, %{
             conversation_id: context.conversation_id,
             owner_visitor_id: context.owner_visitor_id,
             surface: context.surface,
             repository: repository,
             objective: objective
           }) do
        {:ok, job} ->
          {:ok,
           %ExecutionResult{
             result: %{
               "schema" => "sarah.scv_deploy_started.v1",
               "job_ref" => "work-job:#{job.id}",
               "status" => "started",
               "repository" => repository,
               "model" => Scv.model()
             },
             target_receipt_refs: ["work-job:#{job.id}"]
           }}

        {:error, reason} when is_atom(reason) ->
          {:error, reason}

        {:error, _changeset} ->
          {:error, :scv_deploy_start_failed}
      end
    end
  end

  def execute(_arguments, _context), do: {:error, :scv_deploy_request_invalid}

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "repository" => %{
          "type" => "string",
          "maxLength" => 128,
          "description" =>
            "The forge repository to work in, as owner/name, for example OpenAgentsInc/openagents.com"
        },
        "objective" => %{
          "type" => "string",
          "maxLength" => Scv.maximum_objective_bytes(),
          "description" =>
            "The complete objective for the SCV, self-contained enough to run without this conversation"
        }
      },
      "required" => ["repository", "objective"],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "schema" => string(64),
        "job_ref" => string(128),
        "status" => string(16),
        "repository" => string(128),
        "model" => string(128)
      },
      "required" => ["schema", "job_ref", "status", "repository", "model"],
      "additionalProperties" => false
    }
  end

  defp string(maximum), do: %{"type" => "string", "maxLength" => maximum}
end
