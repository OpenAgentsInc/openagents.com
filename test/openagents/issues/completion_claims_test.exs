defmodule OpenAgents.Issues.CompletionClaimsTest do
  @moduledoc """
  Stage 6 of `#10`: store the completion claim, and close an issue from it only
  when a rule that entails the outcome permits.

  The properties under test are the ones that make the rule worth having. A
  claim is graded and stored whether or not it is accepted. Only a
  qualification receipt for the exact revision can satisfy an acceptance
  criterion; a push, a build, and a deployment record and never qualify. A
  repository closes nothing until it opts in twice. A later receipt that
  disagrees contradicts the claim and never reopens the issue. An automatic
  close is attributable to a system principal and is not a person's close.
  """
  use OpenAgents.DataCase, async: true

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Conversations
  alias OpenAgents.Deployments.CheckResult
  alias OpenAgents.Forge.{Assignment, BuildReceipt, DeployReceipt}
  alias OpenAgents.Issues
  alias OpenAgents.Issues.{ClosingReference, ClosingReferences, CompletionClaim}
  alias OpenAgents.Issues.{CompletionClaims, Evidence}
  alias OpenAgents.Machines
  alias OpenAgents.Repo
  alias OpenAgents.Work

  @sha String.duplicate("ab", 20)
  @other_sha String.duplicate("cd", 20)
  @digest "sha256:" <> String.duplicate("9f", 32)

  @scoped_body """
  ## Problem

  Nothing stores a completion claim, so no policy can key on one.

  ## Scope

  The claim record, its grading, and the closure rule.

  ## Acceptance criteria

  - The claim is stored and graded.

  ## Success metrics

  An issue can name which receipt satisfied which criterion.
  """

  @criterion "The claim is stored and graded."

  setup do
    user = repository_user_fixture("claim-author")
    repository = repository_with_member_fixture(user, %{}, "owner")

    {:ok, issue} =
      Issues.create_issue(repository, %{
        title: "Close from a verified outcome",
        body: @scoped_body
      })

    %{user: user, repository: repository, issue: issue}
  end

  describe "the repository has to opt in, twice" do
    test "an unconfigured repository grades not_applicable and closes nothing", context do
      context = with_qualified_attempt(context)

      assert {:ok, claim} = submit(context)
      assert claim.state == "not_applicable"
      assert claim.reasons == ["agents_disabled_repository"]
      refute claim.closed
      assert reload(context.issue).state == "open"
    end

    test "grading on, closing off records an accepted claim and leaves the issue open",
         context do
      context = with_qualified_attempt(context)
      opt_in(context, agents_enabled: true, verified_closing_enabled: false)

      assert {:ok, claim} = submit(context)
      assert claim.state == "accepted"
      refute claim.closed
      assert "closure_withheld:repository_has_not_opted_in" in claim.reasons
      assert reload(context.issue).state == "open"
    end

    test "an absent policy row reads the same as one with both flags false", context do
      assert %{agents_enabled: false, verified_closing_enabled: false} =
               CompletionClaims.policy(context.repository)
    end
  end

  describe "a human's claim is not gated" do
    test "human-authored work grades not_applicable even with both flags on", context do
      context = with_qualified_attempt(context)
      opt_in(context)

      assert {:ok, claim} = CompletionClaims.submit(context.assignment, :human, evidence(context))
      assert claim.state == "not_applicable"
      assert claim.reasons == ["human_only_work"]
      refute claim.closed
      assert reload(context.issue).state == "open"
    end
  end

  describe "an accepted claim closes the issue" do
    setup context do
      context = with_qualified_attempt(context)
      opt_in(context)
      context
    end

    test "the issue closes and names which evidence satisfied which criterion", context do
      assert {:ok, claim} = submit(context)

      assert claim.state == "accepted"
      assert claim.closed
      assert claim.closed_at
      assert [%{"criterion" => @criterion, "evidence" => evidence_id}] = claim.criteria
      assert evidence_id == context.evidence.id
      assert reload(context.issue).state == "closed"
      assert reload(context.issue).state_reason == "completed"
    end

    test "the close is attributed to a system principal and to no person", context do
      assert {:ok, claim} = submit(context)

      assert claim.closed_by_actor == CompletionClaims.closing_actor()
      assert claim.closed_by_actor == "system:accepted-outcome"

      # The one way a reader tells this close from a person's: a person's close
      # leaves a closing reference carrying the user who made it. This one
      # leaves none, because no person asserted anything.
      assert ClosingReferences.for_issue(context.issue) == []
      assert Repo.aggregate(ClosingReference, :count) == 0
    end

    test "the claim records the falsifier the check result could have produced", context do
      assert {:ok, claim} = submit(context)

      assert claim.verifier == "coverage"
      assert claim.falsifier =~ "deployment_check_results:coverage@#{@digest}=failed"
    end

    test "closing this way clears the derived blocked flag on a dependent", context do
      {:ok, dependent} = Issues.create_issue(context.repository, %{title: "Waits on the claim"})
      :ok = Issues.add_dependencies(dependent, [context.issue.number])

      assert Issues.dependencies(reload(dependent)).blocked

      assert {:ok, claim} = submit(context)
      assert claim.closed

      refute Issues.dependencies(reload(dependent)).blocked
    end

    test "resubmitting the same claim regrades in place", context do
      assert {:ok, first} = submit(context)
      assert {:ok, second} = submit(context)

      assert first.id == second.id
      assert Repo.aggregate(CompletionClaim, :count) == 1
    end
  end

  describe "only a qualification receipt can satisfy a criterion" do
    setup context do
      context = with_qualified_attempt(context)
      opt_in(context)
      context
    end

    test "a build receipt for the same commit qualifies nothing", context do
      [build] = Evidence.record_build(build_receipt(context, @sha, "complete"))
      assert build.family == "build"

      assert {:ok, claim} = submit(context, build.id)

      assert claim.state == "incomplete"
      assert "unevidenced_criterion:#{@criterion}" in claim.reasons
      refute claim.closed
      assert reload(context.issue).state == "open"
    end

    test "a deployment receipt for the same commit qualifies nothing", context do
      [deploy] = Evidence.record_deploy(deploy_receipt(context, @sha, "live"))
      assert deploy.family == "deployment"

      assert {:ok, claim} = submit(context, deploy.id)

      assert claim.state == "incomplete"
      assert "unevidenced_criterion:#{@criterion}" in claim.reasons
      refute claim.closed
    end

    test "a succeeded tenant deployment run qualifies nothing", context do
      # The one family word that collides with qualification's: a tenant
      # deployment run reaches the state `succeeded` too. Without the family
      # narrowing, a successful deployment would satisfy an acceptance
      # criterion, which is the exact confusion #150 exists to refuse.
      run = deployment_run(context, "succeeded")
      [deployed] = Evidence.record_deployment_run(run)

      assert deployed.family == "deployment"
      assert deployed.result == "succeeded"

      assert {:ok, claim} = submit(context, deployed.id)

      assert claim.state == "incomplete"
      assert "unevidenced_criterion:#{@criterion}" in claim.reasons
      refute claim.closed
      assert reload(context.issue).state == "open"
    end

    test "another issue's qualification receipt qualifies nothing here", context do
      {:ok, other} =
        Issues.create_issue(context.repository, %{title: "Elsewhere", body: @scoped_body})

      _other_attempt = attempt(%{context | issue: other}, @sha, "completed", budget_snapshot())

      # One check result on the same commit, which both issues claim, so both
      # get an edge. The other issue's edge is a qualification receipt for this
      # exact revision with the qualifying status — identical in every way
      # except the issue it belongs to.
      entries = Evidence.record_check_result(check_result(context, @sha, "succeeded", "shared"))
      elsewhere = Enum.find(entries, &(&1.issue_id == other.id))

      assert elsewhere.family == "qualification"
      assert elsewhere.result == "succeeded"
      assert elsewhere.commit_sha == @sha

      assert {:ok, claim} = submit(context, elsewhere.id)

      assert claim.state == "incomplete"
      assert "unevidenced_criterion:#{@criterion}" in claim.reasons
      refute claim.closed
      assert reload(context.issue).state == "open"
    end

    test "a qualification receipt for another revision qualifies nothing", context do
      # A second attempt on this same issue reported a different revision, and a
      # check passed on that one. The edge is real, it belongs to this issue,
      # it is a qualification receipt and it succeeded — it is simply about
      # bytes this claim is not about.
      _older = attempt(context, @other_sha, "completed", budget_snapshot())

      [other] =
        Evidence.record_check_result(check_result(context, @other_sha, "succeeded", "older"))

      assert other.issue_id == context.issue.id
      assert other.family == "qualification"
      assert other.result == "succeeded"
      assert other.commit_sha == @other_sha

      assert {:ok, claim} = submit(context, other.id)

      assert claim.state == "incomplete"
      assert "unevidenced_criterion:#{@criterion}" in claim.reasons
      refute claim.closed
    end

    test "a failed qualification receipt qualifies nothing", context do
      failed = qualification(context, @sha, "failed", "coverage-red")

      assert {:ok, claim} = submit(context, failed.id)

      assert claim.state == "incomplete"
      refute claim.closed
    end

    test "the two halves are named rather than implied", _context do
      assert CompletionClaims.closing_family() == "qualification"

      assert Enum.sort(CompletionClaims.recording_only_families()) ==
               ~w(build deployment push)
    end
  end

  describe "typed non-accepted results" do
    setup context do
      context = with_qualified_attempt(context)
      opt_in(context)
      context
    end

    test "an issue missing a required section is incomplete by that section's name",
         context do
      {:ok, thin} =
        Issues.update_issue(context.issue, %{"body" => "## Problem\n\nNo other sections.\n"})

      assert {:ok, claim} = submit(%{context | issue: thin})

      assert claim.state == "incomplete"
      assert "missing_issue_section:scope" in claim.reasons
      assert "missing_issue_section:acceptance_criteria" in claim.reasons
      assert "missing_issue_section:success_metrics" in claim.reasons
      refute claim.closed
    end

    test "an attempt with no budget snapshot is incomplete by that field's name", context do
      unbudgeted = attempt(context, @sha, "completed", nil)

      assert {:ok, claim} = CompletionClaims.submit(unbudgeted, :agent, evidence(context))

      assert claim.state == "incomplete"
      assert "missing_attempt_field:budget" in claim.reasons
      refute claim.closed
    end

    test "a criterion naming nothing is incomplete", context do
      assert {:ok, claim} = CompletionClaims.submit(context.assignment, :agent, %{evidence: []})

      assert claim.state == "incomplete"
      assert "unevidenced_criterion:#{@criterion}" in claim.reasons
    end

    test "a self-named false-green class fails a claim its verifier called green",
         context do
      assert {:ok, claim} =
               CompletionClaims.submit(
                 context.assignment,
                 :agent,
                 Map.put(evidence(context), :false_green_classes, ["false_green_mocked_seam"])
               )

      assert claim.state == "failed"
      assert "false_green:false_green_mocked_seam" in claim.reasons
      refute claim.closed
      assert reload(context.issue).state == "open"
    end

    test "a verifier who is also the producer is unauthorized", context do
      # The same user both requested the attempt and published the check. The
      # producer-verifier separation this path always requires is exactly the
      # case where an agent's work grades itself.
      Repo.update_all(
        from(result in CheckResult, where: result.id == ^context.check_result.id),
        set: [published_by_user_id: context.user.id]
      )

      assert {:ok, claim} = submit(context)

      assert claim.state == "unauthorized"
      assert "verifier_not_independent" in claim.reasons
      refute claim.closed
      assert reload(context.issue).state == "open"
    end
  end

  describe "a later receipt that disagrees" do
    setup context do
      context = with_qualified_attempt(context)
      opt_in(context)
      context
    end

    test "a failing build after the close contradicts the claim without reopening",
         context do
      assert {:ok, claim} = submit(context)
      assert claim.closed
      assert is_nil(claim.contradicted_at)

      [failed] = Evidence.record_build(build_receipt(context, @sha, "failed"))

      contradicted = Repo.get!(CompletionClaim, claim.id)
      assert contradicted.contradicted_at
      assert contradicted.contradicted_by_evidence_id == failed.id
      assert contradicted.contradiction_reason == "build:failed"

      # The issue stays closed. Reopening on a later signal is a separate
      # policy with its own failure modes, and this path never has it.
      assert reload(context.issue).state == "closed"
      assert contradicted.closed
    end

    test "a reverted deployment contradicts the claim", context do
      assert {:ok, claim} = submit(context)

      [reverted] = Evidence.record_deploy(deploy_receipt(context, @sha, "reverted"))

      contradicted = Repo.get!(CompletionClaim, claim.id)
      assert contradicted.contradicted_by_evidence_id == reverted.id
      assert contradicted.contradiction_reason == "deployment:reverted"
    end

    test "a successful receipt landing later contradicts nothing", context do
      assert {:ok, claim} = submit(context)

      Evidence.record_build(build_receipt(context, @sha, "complete"))

      assert is_nil(Repo.get!(CompletionClaim, claim.id).contradicted_at)
    end

    test "a failing receipt already on the revision withholds the close", context do
      Evidence.record_build(build_receipt(context, @sha, "failed"))

      assert {:ok, claim} = submit(context)

      assert claim.state == "accepted"
      refute claim.closed
      assert "closure_withheld:contradicting_evidence" in claim.reasons
      assert reload(context.issue).state == "open"
    end
  end

  describe "one closer, not two" do
    setup context do
      context = with_qualified_attempt(context)
      opt_in(context)
      context
    end

    test "an issue #130 already closed records the claim and moves nothing", context do
      reference = closing_reference(context, @other_sha)
      {:ok, closed} = Issues.update_issue(context.issue, %{"state" => "closed"})

      assert {:ok, claim} = CompletionClaims.submit(context.assignment, :agent, evidence(context))

      assert claim.state == "accepted"
      refute claim.closed
      assert "closure_withheld:issue_already_closed" in claim.reasons

      # The person's attribution survives untouched: the trailer close is still
      # the trailer close.
      assert [%ClosingReference{id: id, closed_by_user_id: user_id}] =
               ClosingReferences.for_issue(closed)

      assert id == reference.id
      assert user_id == context.user.id
    end

    test "the database refuses a close on a non-accepted verdict, changeset or not",
         context do
      # The changeset refusal below is what makes the rule legible; this is
      # what makes it true of every row. A writer that skips the changeset
      # entirely still cannot record a close it did not earn.
      assert_raise Postgrex.Error, ~r/issue_completion_claims_close_requires_accepted/, fn ->
        Repo.query!(
          """
          INSERT INTO issue_completion_claims
            (id, repository_id, issue_id, assignment_id, revision, state, reasons,
             criteria, closed, closed_at, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $5, 'incomplete', ARRAY[]::varchar[], ARRAY[]::jsonb[],
                  true, now(), now(), now())
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(context.repository.id),
            context.issue.id,
            Ecto.UUID.dump!(context.assignment.id),
            @sha
          ]
        )
      end
    end

    test "a claim cannot record a close it did not make", context do
      changeset =
        CompletionClaim.changeset(%CompletionClaim{}, %{
          "repository_id" => context.repository.id,
          "issue_id" => context.issue.id,
          "assignment_id" => context.assignment.id,
          "revision" => @sha,
          "state" => "incomplete",
          "closed" => true,
          "closed_at" => DateTime.utc_now()
        })

      refute changeset.valid?
      assert {"requires an accepted outcome", _meta} = changeset.errors[:closed]
    end
  end

  describe "the claim is not a work record" do
    test "it stores no prompt, no report, no budget, and no output", _context do
      fields = CompletionClaim.__schema__(:fields)

      for forbidden <- [:prompt, :report, :budget, :budget_snapshot, :output, :steps, :objective] do
        refute forbidden in fields, "#{forbidden} would make this a second work record"
      end
    end

    test "a private repository's evidence reference stays out of the projection", _context do
      user = repository_user_fixture("private-claimant")
      repository = repository_with_member_fixture(user, %{visibility: "private"}, "owner")

      {:ok, issue} =
        Issues.create_issue(repository, %{title: "Private work", body: @scoped_body})

      context =
        with_qualified_attempt(%{user: user, repository: repository, issue: issue})

      opt_in(context)

      assert {:ok, claim} = submit(context)

      assert claim.state == "accepted"

      assert [%{"criterion" => @criterion, "evidence" => nil, "visibility" => "private"}] =
               claim.criteria
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp submit(context, evidence_id \\ nil) do
    CompletionClaims.submit(context.assignment, :agent, evidence(context, evidence_id))
  end

  defp evidence(context, evidence_id \\ nil) do
    %{evidence: [%{criterion: @criterion, evidence_id: evidence_id || context.evidence.id}]}
  end

  defp opt_in(context, flags \\ [agents_enabled: true, verified_closing_enabled: true]) do
    {:ok, policy} = CompletionClaims.set_policy(context.repository, Map.new(flags), context.user)
    policy
  end

  # An attempt that finished on @sha, a check result published for those exact
  # bytes by somebody other than the requester, and the evidence edge #148
  # writes between them.
  defp with_qualified_attempt(context) do
    assignment = attempt(context, @sha, "completed", budget_snapshot())
    context = Map.put(context, :assignment, assignment)
    result = check_result(context, @sha, "succeeded", "coverage")
    [entry] = Evidence.record_check_result(result)

    context
    |> Map.put(:check_result, result)
    |> Map.put(:evidence, entry)
  end

  defp qualification(context, sha, status, name) do
    [entry] = Evidence.record_check_result(check_result(context, sha, status, name))
    entry
  end

  defp check_result(%{repository: repository}, sha, status, name) do
    %CheckResult{repository_id: repository.id}
    |> CheckResult.changeset(%{
      name: name,
      commit_sha: sha,
      artifact_digest: @digest,
      status: status
    })
    |> Repo.insert!()
  end

  defp build_receipt(%{repository: repository}, sha, status) do
    %BuildReceipt{}
    |> BuildReceipt.start_changeset(%{
      repo: repository.storage_key,
      sha: sha,
      target_id: Ecto.UUID.generate()
    })
    |> Ecto.Changeset.put_change(:status, status)
    |> Repo.insert!()
  end

  defp deployment_run(%{repository: repository, user: user}, state) do
    _environment = OpenAgents.DeploymentsFixtures.environment_fixture(repository, user)
    run = OpenAgents.DeploymentsFixtures.run_fixture(repository, user, %{"commit_sha" => @sha})

    {1, _rows} =
      Repo.update_all(
        from(r in OpenAgents.Deployments.Run, where: r.id == ^run.id),
        set: [state: state]
      )

    Repo.get!(OpenAgents.Deployments.Run, run.id)
  end

  defp deploy_receipt(%{repository: repository}, sha, result) do
    %DeployReceipt{}
    |> DeployReceipt.changeset(%{
      repo: repository.storage_key,
      sha: sha,
      target_id: Ecto.UUID.generate(),
      result: result,
      deployment_type: "direct_load"
    })
    |> Repo.insert!()
  end

  defp closing_reference(%{repository: repository, issue: issue, user: user}, sha) do
    %ClosingReference{}
    |> ClosingReference.changeset(%{
      repository_id: repository.id,
      issue_id: issue.id,
      commit_sha: sha,
      principal: "user:#{user.id}",
      verb: "closes",
      closed: true,
      closed_by_user_id: user.id
    })
    |> Repo.insert!()
  end

  defp attempt(%{repository: repository, issue: issue, user: user}, commit, state, budget) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Assignment{}
    |> Assignment.changeset(%{
      target_kind: "computer",
      machine_id: paired_machine(user, "agent-#{System.unique_integer([:positive])}").id,
      repository_id: repository.id,
      issue_id: issue.id,
      requesting_principal: %{"type" => "user", "id" => user.id},
      branch: "agent/issue-#{issue.number}",
      state: state,
      terminal_commit: commit,
      work_job_id: budget && work_job(budget).id,
      admitted_at: now,
      started_at: now,
      finished_at: now,
      deadline_at: DateTime.add(now, 3600, :second)
    })
    |> Repo.insert!()
  end

  defp budget_snapshot, do: %{"tokens" => 100_000, "seconds" => 900}

  defp work_job(budget) do
    key = "claim-job-#{System.unique_integer([:positive])}"
    {:ok, conversation} = Conversations.ensure_conversation(key)
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "close the issue from a verified outcome",
        budget_snapshot: budget
      })

    job
  end

  defp paired_machine(user, name) do
    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => name,
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => []
      })

    {:ok, machine} = Machines.approve_pairing(user, code)
    machine
  end

  defp reload(issue), do: Repo.get!(Issues.Issue, issue.id)
end
