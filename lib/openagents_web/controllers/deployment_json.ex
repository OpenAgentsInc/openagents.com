defmodule OpenAgentsWeb.DeploymentJson do
  @moduledoc """
  Stable JSON for the deployment control plane.

  Two properties matter more than shape here. Nothing rendered carries a secret
  value: environments expose secret *references*, runs expose a sanitized
  provider receipt, and events expose bounded detail. And every state, reason,
  and policy explanation a client needs in order to know why a deployment is
  waiting is present, because a control plane that says only "failed" forces its
  users to guess.
  """

  alias OpenAgents.Deployments.Approval
  alias OpenAgents.Deployments.CheckResult
  alias OpenAgents.Deployments.Environment
  alias OpenAgents.Deployments.Event
  alias OpenAgents.Deployments.Request
  alias OpenAgents.Deployments.Run
  alias OpenAgents.Deployments.WorkflowGrant

  @doc "Render one environment, including its protection requirements."
  @spec environment(Environment.t()) :: map()
  def environment(%Environment{} = environment) do
    %{
      "name" => environment.name,
      "kind" => environment.kind,
      "provider" => environment.provider,
      "provider_config" => environment.provider_config,
      "secret_references" => environment.secret_references,
      "retention_days" => environment.retention_days,
      "protection" => protection(environment)
    }
  end

  @doc "Render an environment's protection requirements on their own."
  @spec protection(Environment.t()) :: map()
  def protection(%Environment{protection: nil}), do: %{}

  def protection(%Environment{protection: protection}) do
    %{
      "required_checks" => protection.required_checks,
      "required_approvals" => protection.required_approvals,
      "separation_of_duties" => protection.separation_of_duties,
      "approver_roles" => protection.approver_roles,
      "allowed_branches" => protection.allowed_branches,
      "allowed_tags" => protection.allowed_tags,
      "allowed_workflows" => protection.allowed_workflows,
      "window" => %{
        "weekdays" => protection.window_weekdays,
        "start_minute" => protection.window_start_minute,
        "end_minute" => protection.window_end_minute
      },
      "frozen" => protection.frozen,
      "freeze_reason" => protection.freeze_reason,
      "concurrency" => protection.concurrency,
      "maximum_artifact_age_seconds" => protection.maximum_artifact_age_seconds,
      "check_validity_seconds" => protection.check_validity_seconds
    }
  end

  @doc "Render one run, with the request it executes when that is loaded."
  @spec run(Run.t()) :: map()
  def run(%Run{} = run) do
    %{
      "id" => run.id,
      "state" => run.state,
      "result_reason" => run.result_reason,
      "provider" => run.provider,
      "provider_receipt" => run.provider_receipt,
      "policy_explanation" => run.policy_explanation,
      "attempt_count" => run.attempt_count,
      "input_digest" => run.input_digest,
      "cancel_requested" => not is_nil(run.cancel_requested_at),
      "superseded_by_run_id" => run.superseded_by_run_id,
      "started_at" => run.started_at,
      "finished_at" => run.finished_at,
      "created_at" => run.inserted_at,
      "environment" => environment_name(run),
      "request" => request(run)
    }
  end

  @doc "Render one recorded approval decision."
  @spec approval(Approval.t()) :: map()
  def approval(%Approval{} = approval) do
    %{
      "decision" => approval.decision,
      "rule" => approval.rule,
      "request_digest" => approval.request_digest,
      "comment" => approval.comment,
      "decided_at" => approval.decided_at
    }
  end

  @doc "Render one published check result."
  @spec check_result(CheckResult.t()) :: map()
  def check_result(%CheckResult{} = result) do
    %{
      "name" => result.name,
      "commit_sha" => result.commit_sha,
      "artifact_digest" => result.artifact_digest,
      "status" => result.status,
      "evidence_url" => result.evidence_url,
      "evidence_digest" => result.evidence_digest,
      "valid_until" => result.valid_until,
      "published_at" => result.updated_at
    }
  end

  @doc "Render one append-only run event."
  @spec event(Event.t()) :: map()
  def event(%Event{} = event) do
    %{
      "sequence" => event.sequence,
      "type" => event.type,
      "from_state" => event.from_state,
      "to_state" => event.to_state,
      "detail" => event.detail,
      "actor_type" => event.actor_type,
      "occurred_at" => event.occurred_at
    }
  end

  @doc """
  Render a workflow grant and its one-time token.

  The plaintext appears in this response and nowhere else, because only its
  digest is stored.
  """
  @spec workflow_grant(WorkflowGrant.t(), String.t()) :: map()
  def workflow_grant(%WorkflowGrant{} = grant, plaintext) do
    %{
      "id" => grant.id,
      "token" => plaintext,
      "audience" => grant.audience,
      "scopes" => grant.scopes,
      "source_ref" => grant.source_ref,
      "source_workflow" => grant.source_workflow,
      "workflow_run_id" => grant.workflow_run_id,
      "expires_at" => grant.expires_at
    }
  end

  defp request(%Run{deployment_request: %Request{} = request}) do
    %{
      "commit_sha" => request.commit_sha,
      "artifact_digest" => request.artifact_digest,
      "artifact_created_at" => request.artifact_created_at,
      "source_ref" => request.source_ref,
      "source_workflow" => request.source_workflow,
      "principal_type" => request.principal_type,
      "idempotency_key" => request.idempotency_key,
      "request_digest" => request.request_digest,
      "requested_at" => request.requested_at
    }
  end

  defp request(%Run{}), do: nil

  defp environment_name(%Run{environment: %Environment{name: name}}), do: name
  defp environment_name(%Run{}), do: nil
end
