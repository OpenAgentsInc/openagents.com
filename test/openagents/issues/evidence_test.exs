defmodule OpenAgents.Issues.EvidenceTest do
  @moduledoc """
  Stage 4 of `#10`: bind the receipts that evaluated a commit to the issue
  that requested the outcome.

  The properties under test are the ones `#148` and `#69` name. Evidence is an
  edge and never a work record. It binds to the exact commit and the exact
  environment a receipt names, and to no other. Replay writes it once. Failed,
  reverted, and superseded receipts stay. The two deployment planes stay
  distinct. Nothing about the issue record itself changes.
  """
  use OpenAgents.DataCase, async: true

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Deployments.CheckResult
  alias OpenAgents.Forge.{Assignment, BuildReceipt, DeployReceipt, PushReceipt}
  alias OpenAgents.Forge.ReceiptRepository
  alias OpenAgents.Issues
  alias OpenAgents.Issues.{ClosingReference, ClosingReferences, Evidence, EvidenceEntry}
  alias OpenAgents.Machines
  alias OpenAgents.Repo

  @sha String.duplicate("ab", 20)
  @other_sha String.duplicate("cd", 20)

  setup do
    user = repository_user_fixture("evidence-reader")
    repository = repository_with_member_fixture(user, %{}, "owner")
    {:ok, issue} = Issues.create_issue(repository, %{title: "Ship the join"})
    %{user: user, repository: repository, issue: issue}
  end

  describe "an issue with no evidence" do
    test "reads as an empty list rather than an absent fact", %{issue: issue} do
      assert Evidence.for_issue(issue) == []
    end

    test "still appears in a page read", %{repository: repository, issue: issue} do
      {:ok, other} = Issues.create_issue(repository, %{title: "Untouched"})

      evidence = Evidence.for_issues([issue, other])

      assert evidence |> Map.keys() |> Enum.sort() == Enum.sort([issue.id, other.id])
      assert evidence[issue.id] == []
      assert evidence[other.id] == []
    end
  end

  describe "the commit-to-issue half" do
    test "a build receipt reaches the issue a commit trailer closed", context do
      closing_reference(context, @sha)
      receipt = build_receipt(context, @sha, "complete")

      assert [entry] = Evidence.record_build(receipt)
      assert entry.commit_sha == @sha
      assert entry.family == "build"
      assert entry.receipt_id == receipt.id
      assert entry.source == "closing_reference"
      assert entry.result == "complete"
    end

    test "a build receipt reaches the issue an attempt reported a revision for", context do
      attempt(context, @sha, "completed")
      receipt = build_receipt(context, @sha, "complete")

      assert [entry] = Evidence.record_build(receipt)
      assert entry.source == "assignment"
      assert entry.assignment_id
    end

    test "a commit claimed by both a trailer and an attempt records once", context do
      closing_reference(context, @sha)
      attempt(context, @sha, "completed")

      assert [entry] = Evidence.record_build(build_receipt(context, @sha, "complete"))

      # The merge is the stronger fact, so the row is attributed to it and
      # names no attempt, even though an attempt reported the same revision.
      assert entry.source == "closing_reference"
      assert is_nil(entry.assignment_id)
      assert [_one] = Evidence.for_issue(context.issue)
      assert Repo.aggregate(EvidenceEntry, :count) == 1
    end

    test "a receipt for a commit nobody claims records nothing", context do
      assert Evidence.record_build(build_receipt(context, @other_sha, "complete")) == []
      assert Evidence.for_issue(context.issue) == []
    end
  end

  describe "consuming the commit-trailer extraction" do
    test "the push path records the push receipt as evidence", context do
      %{repository: repository, user: user, issue: issue} = context
      push = push_receipt(context, 7)

      assert [_reference] =
               ClosingReferences.apply_commit(
                 repository,
                 user,
                 @sha,
                 "Ship it\n\nCloses ##{issue.number}\n",
                 repo: repository.storage_key,
                 wal_seq: 7,
                 push_receipt_id: push.id,
                 principal: "user:#{user.id}"
               )

      assert [entry] = Evidence.for_issue(issue)
      assert entry.family == "push"
      assert entry.plane == "forge"
      assert entry.receipt_id == push.id
      assert entry.commit == @sha
      assert entry.source == "closing_reference"
    end

    test "re-presenting the same commit writes no second edge", context do
      %{repository: repository, user: user, issue: issue} = context
      push = push_receipt(context, 8)

      apply = fn ->
        ClosingReferences.apply_commit(
          repository,
          user,
          @sha,
          "Ship it\n\nCloses ##{issue.number}\n",
          repo: repository.storage_key,
          wal_seq: 8,
          push_receipt_id: push.id,
          principal: "user:#{user.id}"
        )
      end

      apply.()
      apply.()

      assert [_one] = Evidence.for_issue(issue)
    end

    test "a commit that names no issue records nothing", context do
      %{repository: repository, user: user, issue: issue} = context
      push = push_receipt(context, 9)

      assert ClosingReferences.apply_commit(
               repository,
               user,
               @sha,
               "Refactor the reader\n",
               push_receipt_id: push.id,
               principal: "user:#{user.id}"
             ) == []

      assert Evidence.for_issue(issue) == []
    end
  end

  describe "the exact commit and environment" do
    test "a receipt asserted against another commit is refused", context do
      closing_reference(context, @sha)
      receipt = build_receipt(context, @sha, "complete")

      assert {:error, :evidence_commit_mismatch} =
               Evidence.record(%{
                 family: "build",
                 receipt_id: receipt.id,
                 commit_sha: @other_sha,
                 actor: "user:#{context.user.id}"
               })

      assert Evidence.for_issue(context.issue) == []
    end

    test "a deployment receipt asserted against another environment is refused", context do
      closing_reference(context, @sha)
      receipt = deploy_receipt(context, @sha, "live")

      assert {:error, :evidence_environment_mismatch} =
               Evidence.record(%{
                 family: "deployment",
                 receipt_id: receipt.id,
                 environment: "staging",
                 actor: "user:#{context.user.id}"
               })

      assert Evidence.for_issue(context.issue) == []
    end

    test "a push receipt is never a deployment receipt", context do
      closing_reference(context, @sha)

      push =
        %PushReceipt{}
        |> PushReceipt.changeset(%{
          repo: context.repository.storage_key,
          wal_seq: 1,
          principal: "user:#{context.user.id}",
          refs: %{}
        })
        |> Repo.insert!()

      assert {:error, :evidence_receipt_not_found} =
               Evidence.record(%{
                 family: "deployment",
                 receipt_id: push.id,
                 actor: "user:#{context.user.id}"
               })

      # And a push receipt cannot resolve its own commit either, which is why
      # `record_push/5` writes that edge where the commit is known.
      assert {:error, :evidence_push_needs_commit} =
               Evidence.record(%{
                 family: "push",
                 receipt_id: push.id,
                 actor: "user:#{context.user.id}"
               })
    end
  end

  describe "idempotency" do
    test "recording the same receipt twice writes one edge", context do
      closing_reference(context, @sha)
      receipt = build_receipt(context, @sha, "complete")

      assert [_written] = Evidence.record_build(receipt)
      assert Evidence.record_build(receipt) == []
      assert [_one] = Evidence.for_issue(context.issue)
    end

    test "an attempt binding a revision whose receipts exist writes each once", context do
      closing_reference(context, @sha)
      _build = build_receipt(context, @sha, "complete")
      _deploy = deploy_receipt(context, @sha, "live")

      bound = attempt(context, @sha, "completed")

      assert length(Evidence.bind_attempt(bound)) == 2
      assert Evidence.bind_attempt(bound) == []

      families = context.issue |> Evidence.for_issue() |> Enum.map(& &1.family) |> Enum.sort()
      assert families == ["build", "deployment"]
    end
  end

  describe "history" do
    test "a failed build and a reverted deployment both keep their edge", context do
      closing_reference(context, @sha)

      assert [failed] = Evidence.record_build(build_receipt(context, @sha, "failed"))
      assert [reverted] = Evidence.record_deploy(deploy_receipt(context, @sha, "reverted"))

      assert failed.result == "failed"
      assert reverted.result == "reverted"
      assert length(Evidence.for_issue(context.issue)) == 2
    end

    test "several deployment attempts against one issue all survive", context do
      closing_reference(context, @sha)

      Evidence.record_deploy(deploy_receipt(context, @sha, "failed"))
      Evidence.record_deploy(deploy_receipt(context, @sha, "live"))

      results =
        context.issue
        |> Evidence.for_issue()
        |> Enum.filter(&(&1.family == "deployment"))
        |> Enum.map(& &1.result)
        |> Enum.sort()

      assert results == ["failed", "live"]
    end
  end

  describe "the two deployment planes" do
    test "a forge deployment receipt names the forge plane and its fleet", context do
      closing_reference(context, @sha)

      assert [entry] = Evidence.record_deploy(deploy_receipt(context, @sha, "live"))
      assert entry.plane == "forge"
      assert entry.environment == "fleet"
    end

    test "a qualification receipt binds the exact commit it examined", context do
      closing_reference(context, @sha)

      result =
        %CheckResult{repository_id: context.repository.id}
        |> CheckResult.changeset(%{
          name: "suite",
          commit_sha: @sha,
          artifact_digest: "sha256:" <> String.duplicate("e", 64),
          status: "succeeded"
        })
        |> Repo.insert!()

      assert [entry] = Evidence.record_check_result(result)
      assert entry.family == "qualification"
      assert entry.plane == "tenant"
      assert entry.result == "succeeded"
    end
  end

  describe "the projection" do
    test "never carries the attempt, the actor, or the repository", context do
      closing_reference(context, @sha)
      Evidence.record_build(build_receipt(context, @sha, "complete"))

      assert [summary] = Evidence.for_issue(context.issue)

      for key <- [:actor, :assignment_id, :repository_id, :issue_id] do
        refute Map.has_key?(summary, key), "#{key} must stay off the issue projection"
      end

      assert summary.commit == @sha
      assert summary.receipt_id
    end

    test "evidence on another issue never leaks into this one", context do
      {:ok, other} = Issues.create_issue(context.repository, %{title: "Different work"})

      closing_reference(context, @sha)
      closing_reference(%{context | issue: other}, @other_sha)

      Evidence.record_build(build_receipt(context, @sha, "complete"))
      Evidence.record_build(build_receipt(context, @other_sha, "complete"))

      assert [%{commit: @sha}] = Evidence.for_issue(context.issue)
      assert [%{commit: @other_sha}] = Evidence.for_issue(other)
    end
  end

  describe "which repository a receipt names" do
    # `forge_builds.repo` holds a repository *name*, and `repositories` is
    # unique on `{namespace_id, name_key}` rather than on `name`. Before #181
    # this receipt recorded no evidence at all: two repositories answered to
    # the name, and attaching it to the wrong issue is worse than attaching it
    # to none. The key settles it without a name lookup.
    test "a receipt whose name two repositories answer to is still evidence", context do
      %{repository: repository, issue: issue} = context
      closing_reference(context, @sha)

      _decoy =
        repository_fixture(%{owner: "EvidenceDecoy", name: repository.name, visibility: "public"})

      assert ReceiptRepository.resolve(repository.name) == nil

      receipt = named_build_receipt(repository, repository.name, repository.id, @sha)

      assert [entry] = Evidence.record_build(receipt)
      assert entry.issue_id == issue.id
      assert entry.receipt_id == receipt.id
    end

    # The refusal survives for a row the backfill could not settle. This is the
    # honest half: a null key is "not settled", and the name behind it still
    # answers for two repositories, so nothing is recorded.
    test "a receipt with no key whose name is ambiguous records nothing", context do
      %{repository: repository} = context
      closing_reference(context, @sha)

      _decoy =
        repository_fixture(%{
          owner: "EvidenceDecoy2",
          name: repository.name,
          visibility: "public"
        })

      receipt = named_build_receipt(repository, repository.name, nil, @sha)

      assert Evidence.record_build(receipt) == []
    end

    test "a receipt naming a repository the forge does not track records nothing", context do
      closing_reference(context, @sha)
      receipt = named_build_receipt(context.repository, "gone-from-the-forge", nil, @sha)

      assert Evidence.record_build(receipt) == []
    end

    # A repository whose name and storage key differ is the ordinary case:
    # every repository created since storage keys became UUIDs is one. The
    # sweep restricted itself to `receipt_repo_keys(storage_key)`, which does
    # not contain the name a build receipt is actually written with, so the
    # key is what finds it.
    test "the sweep finds a receipt written under a name, not a storage key", context do
      %{repository: repository, issue: issue, user: user} = context
      refute repository.storage_key == repository.name

      receipt = named_build_receipt(repository, repository.name, repository.id, @sha)
      assignment = attempt(context, @sha, "completed")

      assert Evidence.bind_attempt(assignment) != []

      entries = Evidence.for_issue(issue)
      assert Enum.any?(entries, &(&1.receipt_id == receipt.id and &1.family == "build"))
      assert user
    end
  end

  describe "the edge is never a work record" do
    test "an edge stores no steps, no report, and no budget", _context do
      fields = EvidenceEntry.__schema__(:fields)

      for forbidden <- [:steps, :report, :budget, :budget_snapshot, :prompt, :output] do
        refute forbidden in fields, "#{forbidden} would make this a second work record"
      end
    end

    test "deleting an issue removes its edges and leaves the receipts", context do
      closing_reference(context, @sha)
      receipt = build_receipt(context, @sha, "complete")
      assert [_entry] = Evidence.record_build(receipt)

      Repo.delete!(context.issue)

      assert Repo.aggregate(EvidenceEntry, :count) == 0
      assert Repo.get(BuildReceipt, receipt.id)
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────

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

  defp named_build_receipt(_repository, repo, repository_id, sha) do
    %BuildReceipt{}
    |> BuildReceipt.start_changeset(%{
      repo: repo,
      repository_id: repository_id,
      sha: sha,
      target_id: Ecto.UUID.generate()
    })
    |> Ecto.Changeset.put_change(:status, "complete")
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

  defp attempt(%{repository: repository, issue: issue, user: user}, commit, state) do
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
      admitted_at: now,
      started_at: now,
      finished_at: now,
      deadline_at: DateTime.add(now, 3600, :second)
    })
    |> Repo.insert!()
  end

  defp push_receipt(%{repository: repository, user: user}, seq) do
    %PushReceipt{}
    |> PushReceipt.changeset(%{
      repo: repository.storage_key,
      wal_seq: seq,
      principal: "user:#{user.id}",
      refs: %{}
    })
    |> Repo.insert!()
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
end
