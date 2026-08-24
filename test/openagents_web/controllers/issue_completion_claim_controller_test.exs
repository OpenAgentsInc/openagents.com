defmodule OpenAgentsWeb.IssueCompletionClaimControllerTest do
  @moduledoc """
  The one route a completion claim arrives on.

  The properties under test are about authority and about what the request may
  say. An agent may claim only for the attempt it requested. A user may claim
  for any attempt in a repository it can write, and its claim is
  `not_applicable` because the contract gates agent-authored claims. A path
  that names another repository resolves to nothing.
  """
  use OpenAgentsWeb.ConnCase, async: true

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Agents
  alias OpenAgents.Conversations
  alias OpenAgents.Deployments.CheckResult
  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Issues
  alias OpenAgents.Issues.{CompletionClaims, Evidence}
  alias OpenAgents.Machines
  alias OpenAgents.Repo
  alias OpenAgents.Work

  @sha String.duplicate("ab", 20)
  @digest "sha256:" <> String.duplicate("7c", 32)

  @scoped_body """
  ## Problem

  A claim has no route to arrive on.

  ## Scope

  One endpoint on the issue.

  ## Acceptance criteria

  - The route grades and stores the claim.

  ## Success metrics

  A client can read back what it claimed.
  """

  @criterion "The route grades and stores the claim."

  setup do
    owner = repository_user_fixture("claim-route-owner")
    repository = repository_with_member_fixture(owner, %{}, "owner")

    {:ok, issue} =
      Issues.create_issue(repository, %{title: "Claim over HTTP", body: @scoped_body})

    {:ok, agent, credential} =
      Agents.register(%{
        handle: "claim-agent-#{System.unique_integer([:positive])}",
        display_name: "Claim agent",
        registration_ip: "192.0.2.52"
      })

    assignment = attempt(repository, issue, owner, %{"type" => "agent", "id" => agent.id})
    result = check_result(repository, @sha, "succeeded")
    [entry] = Evidence.record_check_result(result)

    %{
      owner: owner,
      repository: repository,
      issue: issue,
      agent: agent,
      credential: credential,
      assignment: assignment,
      evidence: entry
    }
  end

  test "the agent that requested the attempt closes an opted-in issue", context do
    {:ok, _policy} =
      CompletionClaims.set_policy(
        context.repository,
        %{agents_enabled: true, verified_closing_enabled: true},
        context.owner
      )

    conn = post_claim(build_conn(), context, "Bearer #{context.credential}")

    assert %{"claim" => claim, "issue" => %{"state" => "closed"}} = json_response(conn, 201)
    assert claim["state"] == "accepted"
    assert claim["closed"] == true
    assert claim["closed_by_actor"] == "system:accepted-outcome"
    assert [%{"criterion" => @criterion}] = claim["criteria"]
  end

  test "an agent that did not request the attempt is refused", context do
    {:ok, _other, other_credential} =
      Agents.register(%{
        handle: "other-claim-agent-#{System.unique_integer([:positive])}",
        display_name: "Other agent",
        registration_ip: "192.0.2.53"
      })

    conn = post_claim(build_conn(), context, "Bearer #{other_credential}")

    assert json_response(conn, 403)["code"] == "forbidden"
    assert Repo.get!(Issues.Issue, context.issue.id).state == "open"
  end

  test "a user who can write the repository records a not_applicable claim", context do
    conn =
      build_conn()
      |> put_forge_api_token("claim-writer", context.repository)
      |> post_claim_conn(context)

    assert %{"claim" => claim, "issue" => %{"state" => "open"}} = json_response(conn, 201)
    assert claim["state"] == "not_applicable"
    assert claim["reasons"] == ["human_only_work"]
  end

  test "a user with no write authority is refused", context do
    conn =
      build_conn()
      |> put_forge_api_token("claim-outsider")
      |> post_claim_conn(context)

    assert json_response(conn, 403)["code"] == "forbidden"
  end

  test "a path naming another repository resolves to nothing", context do
    elsewhere = repository_with_member_fixture(context.owner, %{}, "owner")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{context.credential}")
      |> post(
        ~p"/api/v3/repos/#{elsewhere.owner}/#{elsewhere.name}/issues/#{context.issue.number}/completion_claim",
        %{
          "assignment_id" => context.assignment.id,
          "evidence" => [%{"criterion" => @criterion, "evidence_id" => context.evidence.id}]
        }
      )

    assert json_response(conn, 404)["code"] == "not_found"
  end

  test "the issue response carries the claim it recorded", context do
    {:ok, _policy} =
      CompletionClaims.set_policy(
        context.repository,
        %{agents_enabled: true, verified_closing_enabled: true},
        context.owner
      )

    conn = post_claim(build_conn(), context, "Bearer #{context.credential}")
    assert json_response(conn, 201)

    conn =
      get(
        build_conn(),
        ~p"/api/v3/repos/#{context.repository.owner}/#{context.repository.name}/issues/#{context.issue.number}"
      )

    assert %{"openagents" => %{"completion_claims" => [claim]}} = json_response(conn, 200)
    assert claim["state"] == "accepted"
    assert claim["revision"] == @sha
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp post_claim(conn, context, authorization) do
    conn
    |> put_req_header("authorization", authorization)
    |> post_claim_conn(context)
  end

  defp post_claim_conn(conn, context) do
    post(
      conn,
      ~p"/api/v3/repos/#{context.repository.owner}/#{context.repository.name}/issues/#{context.issue.number}/completion_claim",
      %{
        "assignment_id" => context.assignment.id,
        "evidence" => [%{"criterion" => @criterion, "evidence_id" => context.evidence.id}]
      }
    )
  end

  defp check_result(repository, sha, status) do
    %CheckResult{repository_id: repository.id}
    |> CheckResult.changeset(%{
      name: "route-coverage",
      commit_sha: sha,
      artifact_digest: @digest,
      status: status
    })
    |> Repo.insert!()
  end

  defp attempt(repository, issue, user, principal) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Assignment{}
    |> Assignment.changeset(%{
      target_kind: "computer",
      machine_id: paired_machine(user).id,
      repository_id: repository.id,
      issue_id: issue.id,
      requesting_principal: principal,
      branch: "agent/issue-#{issue.number}",
      state: "completed",
      terminal_commit: @sha,
      work_job_id: work_job().id,
      admitted_at: now,
      started_at: now,
      finished_at: now,
      deadline_at: DateTime.add(now, 3600, :second)
    })
    |> Repo.insert!()
  end

  defp work_job do
    key = "claim-route-job-#{System.unique_integer([:positive])}"
    {:ok, conversation} = Conversations.ensure_conversation(key)
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "claim completion over the route",
        budget_snapshot: %{"tokens" => 50_000}
      })

    job
  end

  defp paired_machine(user) do
    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => "claim-route-machine-#{System.unique_integer([:positive])}",
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => []
      })

    {:ok, machine} = Machines.approve_pairing(user, code)
    machine
  end
end
