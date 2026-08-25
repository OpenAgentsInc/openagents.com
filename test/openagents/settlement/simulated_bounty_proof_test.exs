defmodule OpenAgents.Settlement.SimulatedBountyProofTest do
  @moduledoc """
  Issue `#207`: prove settlement once, on a simulated rail.

  `test/openagents/settlement_test.exs` proves every clause of `SETTLEMENT-001`
  in isolation, but it proves them against invented material: a commit sha of
  forty `a` characters, a work-job reference that names no work job, an
  evidence digest over nothing, and a gateway module private to that file.
  Each clause holds; the loop has never been driven.

  This file drives it, once, on real material:

    1. A repository with a real bare git repository behind it, and a real
       commit object in it. The sha the treasury pays for is a sha `git
       cat-file` resolves, not a string that matches a regex.
    2. An issue scoped to the accepted-outcome contract's four sections and
       labelled `bounty`.
    3. Real accepted work: an attempt bound to that commit, a qualification
       receipt published by someone who is not the requester, and a durable
       `OUTCOME-001` completion claim that grades `accepted` and closes the
       issue under the repository's two opt-ins.
    4. `SETTLEMENT-001` over that: an admitted treasury policy, a specification
       priced in whole sats and fingerprinted, a claim pinned to the
       fingerprint and to the claimant's own bolt12 offer, a verification of
       that exact commit whose evidence digest is taken over the completion
       claim, and a settlement carrying an approval reference and an
       idempotency key.
    5. A payment on `OpenAgents.Settlement.PaymentGateway.Simulated`, which
       moves no sats and holds no key, and stamps `simulated:` on the receipt
       so no reader can mistake it for a transfer.

  Then the parts that make "once" mean once: a replayed request returns the
  first receipt, a second idempotency key cannot pay again, the public
  projection carries the evidence chain and none of the private facts, and the
  claimant exports a receipt that needs no hosted wallet.

  No money moves here and nothing in this repository can make it move. Outbound
  payout lives on the self-custodial MoneyDevKit treasury bridge, outside this
  codebase; what is proven here is the authority chain that would authorize one.

  Two gaps this proof exposes rather than closes are named at the assertions
  that would otherwise hide them: settlement never asks the forge whether the
  commit it pays for exists, and nothing requires the verification's evidence
  digest to be taken over an accepted completion claim. The test does both by
  hand.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures
  import OpenAgents.ForgePromotionFixtures

  alias OpenAgents.Conversations
  alias OpenAgents.Deployments.CheckResult
  alias OpenAgents.Forge.{Assignment, Browse}
  alias OpenAgents.Issues
  alias OpenAgents.Issues.{CompletionClaims, Evidence}
  alias OpenAgents.Machines
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Settlement
  alias OpenAgents.Settlement.{Claim, PaymentGateway, PaymentIntent, PaymentReceipt}
  alias OpenAgents.Work

  @amount_sats 2_500

  @artifact_digest "sha256:" <> String.duplicate("9f", 32)

  @criterion "The bounty settles once against fingerprinted evidence."

  @scoped_body """
  ## Problem

  Settlement has never been driven end to end, so the loop is a claim rather
  than a fact.

  ## Scope

  One sats-priced bounty, from pricing to receipt, on a simulated rail.

  ## Acceptance criteria

  - The bounty settles once against fingerprinted evidence.

  ## Success metrics

  The receipt chain reconciles from the issue to the payment and back.
  """

  setup do
    isolate_forge_storage!()

    configured_gateway = Application.get_env(:openagents, :settlement_payment_gateway)
    configured_visibility = Application.get_env(:openagents, :forge_public_visibility)
    configured_environment = Application.get_env(:openagents, :runtime_environment)

    Application.put_env(
      :openagents,
      :settlement_payment_gateway,
      PaymentGateway.Simulated
    )

    on_exit(fn ->
      restore(:settlement_payment_gateway, configured_gateway)
      restore(:forge_public_visibility, configured_visibility)
      restore(:runtime_environment, configured_environment)
    end)

    # The buyer of the work and the owner of the repository. Somebody other
    # than this principal publishes the check, or the attempt would be
    # `unauthorized` under OUTCOME-001's producer-verifier separation.
    buyer = repository_user_fixture("bounty-buyer")
    repository = repository_with_member_fixture(buyer, %{}, "owner")

    # A real bare repository with a real commit in it, so the sha the treasury
    # pays for is one the forge can resolve.
    commit_sha = seeded_commit(repository.storage_key, "settle the bounty")

    {:ok, issue} =
      Issues.create_issue(repository, %{
        title: "Prove settlement once",
        body: @scoped_body
      })

    {:ok, issue} = Issues.add_labels(issue, ["bounty"], buyer)

    %{buyer: buyer, repository: repository, issue: issue, commit_sha: commit_sha}
  end

  describe "one sats-priced bounty, end to end, on the simulated rail" do
    test "it is priced, claimed, completed, verified, and paid exactly once", context do
      %{issue: issue, repository: repository, commit_sha: commit_sha} = context

      # ── the commit is real ───────────────────────────────────────────────
      # Settlement itself only checks the sha's shape (`validate_commit_sha/1`
      # is a regex). This proof resolves it through the forge so the payment
      # below is demonstrably for delivered bytes rather than a well-formed
      # string.
      assert {:ok, ^commit_sha} = Browse.resolve_commit(repository.storage_key, commit_sha)
      assert String.match?(commit_sha, ~r/\A[0-9a-f]{40}\z/)

      # ── the issue carries the bounty label ───────────────────────────────
      assert Enum.any?(issue.labels, &(&1["name"] == "bounty"))

      # ── the work is really accepted (OUTCOME-001) ────────────────────────
      completion = accepted_completion(context)

      assert completion.state == "accepted"
      assert completion.revision == commit_sha
      assert completion.closed
      assert completion.closed_by_actor == "system:accepted-outcome"
      assert Repo.get!(Issues.Issue, issue.id).state == "closed"

      # ── the treasury admits a policy that bounds every payment ───────────
      assert {:ok, policy} = Settlement.admit_treasury_policy(operator())
      assert policy.rules["unit"] == "sat"
      assert policy.rules["custody"] == "claimant_self_custodial_destination"
      assert is_integer(policy.rules["max_payment_sats"])
      assert is_integer(policy.rules["daily_budget_sats"])

      # ── the bounty is priced in whole sats and fingerprinted ─────────────
      assert {:ok, spec} = Settlement.price_bounty(issue, price_attributes(), operator())
      assert spec.amount_sats == @amount_sats
      assert is_integer(spec.amount_sats)
      assert spec.revision == 1
      assert String.match?(spec.spec_fingerprint, ~r/\A[0-9a-f]{64}\z/)
      assert Settlement.current_spec(issue).id == spec.id

      # ── the claimant claims it with their own destination ────────────────
      claimant = claimant(context, completion)
      assert {:ok, claim} = Settlement.claim_bounty(spec, claimant)
      assert claim.spec_fingerprint == spec.spec_fingerprint
      assert claim.state == "claimed"
      assert claim.destination == claimant.destination
      assert claim.destination_kind == "bolt12_offer"
      # The treasury records a digest of the destination and never a wallet of
      # its own for the claimant.
      assert claim.destination_digest == Canonical.sha256(claimant.destination)

      # ── the delivery is verified at that exact commit ────────────────────
      # SETTLEMENT-001 requires the verification to accept the exact commit the
      # claim delivered. It does not require the evidence digest to be taken
      # over an accepted completion claim, so this proof takes it over one.
      evidence_digest = completion_digest(issue, completion)

      assert {:ok, verification} =
               Settlement.verify_claim(claim, %{
                 commit_sha: commit_sha,
                 verifier_ref: "verifier:forge-qualification",
                 evidence_digest: evidence_digest,
                 outcome: "accepted",
                 reason_code: "acceptance_criteria_met",
                 auth_method: "session",
                 decision_receipt_ref: "decision:completion-claim:#{completion.id}",
                 work_job_ref: claimant.work_job_ref
               })

      assert verification.outcome == "accepted"
      assert verification.commit_sha == commit_sha
      assert verification.evidence_digest == evidence_digest
      assert verification.verifier_policy_digest == Canonical.digest!(spec.verification_policy)
      assert Repo.get!(Claim, claim.id).state == "verified"

      # ── the green above could have been red ──────────────────────────────
      # A different commit has no verification of its own, so the treasury
      # refuses it. Nothing here pays because a claim exists; it pays because
      # this commit was verified.
      other_sha = String.duplicate("a", 40)
      assert {:error, :not_found} = Browse.resolve_commit(repository.storage_key, other_sha)

      assert {:error, :stale_commit} =
               Settlement.settle(
                 Repo.get!(Claim, claim.id),
                 settlement_request(other_sha)
               )

      assert Repo.aggregate(PaymentReceipt, :count) == 0

      # ── the treasury pays, once, on a rail that moves nothing ────────────
      request = settlement_request(commit_sha)
      assert {:ok, settled} = Settlement.settle(claim, request)

      assert settled.claim.state == "paid"
      assert settled.intent.state == "paid"
      assert settled.intent.attempts == 1
      assert settled.intent.commit_sha == commit_sha
      assert settled.receipt.amount_sats == @amount_sats

      # Sats are integers on every field of the paid path.
      assert is_integer(settled.intent.amount_sats)
      assert is_integer(settled.receipt.amount_sats)
      assert is_integer(settled.receipt.fee_sats)

      # The receipt says on its face that no money moved.
      assert String.starts_with?(
               settled.receipt.gateway_ref,
               PaymentGateway.Simulated.gateway_ref_prefix()
             )

      assert String.match?(settled.receipt.payment_hash, ~r/\A[0-9a-f]{64}\z/)
      assert String.match?(settled.receipt.receipt_digest, ~r/\A[0-9a-f]{64}\z/)

      # ── once means once ──────────────────────────────────────────────────
      # The same key returns the first receipt.
      assert {:ok, replayed} = Settlement.settle(Repo.get!(Claim, claim.id), request)
      assert replayed.receipt.id == settled.receipt.id

      # A fresh key cannot pay the same claim again.
      assert {:error, {:claim_not_settleable, "paid"}} =
               Settlement.settle(
                 Repo.get!(Claim, claim.id),
                 settlement_request(commit_sha)
               )

      assert Repo.aggregate(PaymentReceipt, :count) == 1
      assert Repo.aggregate(PaymentIntent, :count) == 1

      # ── the public can read the chain, and none of the private facts ─────
      publish(repository, :l2)
      projection = Settlement.public_projection(Repo.get!(Issues.Issue, issue.id))

      assert projection["contract"] == "openagents.settlement.public.v1"
      assert projection["issue_number"] == issue.number
      assert projection["unit"] == "sat"
      assert projection["amount_sats"] == @amount_sats
      assert projection["state"] == "paid"
      assert projection["paid"] == true
      assert projection["commit_sha"] == commit_sha
      assert projection["spec_fingerprint"] == spec.spec_fingerprint
      assert projection["payment_hash"] == settled.receipt.payment_hash

      for private <- ~w(destination destination_digest claimant_ref buyer_ref work_job_ref
                        actor_id approval_receipt_ref gateway_ref preimage_digest) do
        refute Map.has_key?(projection, private)
      end

      # ── the claimant takes their receipt with them ───────────────────────
      assert {:ok, export} =
               Settlement.export_payment_receipt(
                 Repo.get!(Claim, claim.id),
                 claimant.claimant_ref
               )

      assert export["contract"] == "openagents.settlement.payment-receipt.v1"
      assert export["issue"]["number"] == issue.number
      assert export["issue"]["repository"] == repository.name
      assert export["unit"] == "sat"
      assert export["amount_sats"] == @amount_sats
      assert export["commit_sha"] == commit_sha
      assert export["destination"] == claimant.destination
      assert export["verification_evidence_digest"] == evidence_digest
      assert export["payment_hash"] == settled.receipt.payment_hash

      # Whatever the export carries, it carries no operator identity and no
      # gateway credential.
      for private <- ~w(actor_id approval_receipt_ref gateway_ref operator_id) do
        refute Map.has_key?(export, private)
      end
    end
  end

  describe "the simulated rail is safe to ship" do
    test "it refuses in production, so a misconfigured treasury fakes no payment", context do
      Application.put_env(:openagents, :runtime_environment, :production)

      refute PaymentGateway.Simulated.admitted?()

      assert {:error, "simulated_gateway_refused_in_production"} =
               PaymentGateway.Simulated.pay(gateway_request(context))

      # And the refusal reaches the domain as a failed attempt on a live
      # intent, not as a payment.
      %{claim: claim, commit_sha: commit_sha} = verified_claim(context)

      assert {:error, {:payment_failed, "simulated_gateway_refused_in_production"}} =
               Settlement.settle(claim, settlement_request(commit_sha))

      assert Repo.aggregate(PaymentReceipt, :count) == 0
      assert Repo.get_by!(PaymentIntent, claim_id: claim.id).state == "failed"
    end

    test "it refuses a sats amount that is not a positive integer", context do
      request = gateway_request(context)

      assert {:error, "simulated_amount_sats_not_a_positive_integer"} =
               PaymentGateway.Simulated.pay(%{request | amount_sats: 2_500.0})

      assert {:error, "simulated_amount_sats_not_a_positive_integer"} =
               PaymentGateway.Simulated.pay(%{request | amount_sats: 0})
    end

    test "it vouches for no key it was never handed" do
      assert {:unknown, nil} = PaymentGateway.Simulated.lookup("settlement-never-dispatched")
    end
  end

  # ── the accepted work ─────────────────────────────────────────────────────

  # An attempt that finished on the real commit, a qualification receipt for
  # those exact bytes published by somebody who is not the requester, and the
  # durable completion claim OUTCOME-001 grades from them.
  defp accepted_completion(context) do
    %{repository: repository, buyer: buyer, commit_sha: commit_sha} = context

    {:ok, _policy} =
      CompletionClaims.set_policy(
        repository,
        %{agents_enabled: true, verified_closing_enabled: true},
        buyer
      )

    assignment = attempt(context)

    check =
      %CheckResult{repository_id: repository.id}
      |> CheckResult.changeset(%{
        name: "precommit",
        commit_sha: commit_sha,
        artifact_digest: @artifact_digest,
        status: "succeeded"
      })
      |> Repo.insert!()

    [entry] = Evidence.record_check_result(check)

    {:ok, completion} =
      CompletionClaims.submit(assignment, :agent, %{
        evidence: [%{criterion: @criterion, evidence_id: entry.id}]
      })

    Map.put(completion, :assignment, assignment)
  end

  defp attempt(context) do
    %{repository: repository, issue: issue, buyer: buyer, commit_sha: commit_sha} = context
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Assignment{}
    |> Assignment.changeset(%{
      target_kind: "computer",
      machine_id: paired_machine(buyer).id,
      repository_id: repository.id,
      issue_id: issue.id,
      requesting_principal: %{"type" => "user", "id" => buyer.id},
      branch: "agent/issue-#{issue.number}",
      state: "completed",
      terminal_commit: commit_sha,
      work_job_id: work_job().id,
      admitted_at: now,
      started_at: now,
      finished_at: now,
      deadline_at: DateTime.add(now, 3600, :second)
    })
    |> Repo.insert!()
  end

  defp work_job do
    key = "bounty-job-#{unique()}"
    {:ok, conversation} = Conversations.ensure_conversation(key)
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "settle one sats-priced bounty",
        budget_snapshot: %{"tokens" => 100_000, "seconds" => 900}
      })

    job
  end

  defp paired_machine(user) do
    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => "bounty-agent-#{unique()}",
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => []
      })

    {:ok, machine} = Machines.approve_pairing(user, code)
    machine
  end

  # ── the settlement material ───────────────────────────────────────────────

  defp verified_claim(context) do
    %{issue: issue, commit_sha: commit_sha} = context
    completion = accepted_completion(context)

    {:ok, _policy} = Settlement.admit_treasury_policy(operator())
    {:ok, spec} = Settlement.price_bounty(issue, price_attributes(), operator())
    claimant = claimant(context, completion)
    {:ok, claim} = Settlement.claim_bounty(spec, claimant)

    {:ok, _verification} =
      Settlement.verify_claim(claim, %{
        commit_sha: commit_sha,
        verifier_ref: "verifier:forge-qualification",
        evidence_digest: completion_digest(issue, completion),
        outcome: "accepted",
        reason_code: "acceptance_criteria_met",
        auth_method: "session",
        decision_receipt_ref: "decision:completion-claim:#{completion.id}"
      })

    %{claim: Repo.get!(Claim, claim.id), spec: spec, commit_sha: commit_sha}
  end

  # The settlement's evidence digest, taken over the accepted completion claim
  # so the payment is bound to the graded outcome and not to a free hex string.
  defp completion_digest(issue, completion) do
    Canonical.digest!(%{
      "contract" => "openagents.accepted-outcome.v1",
      "issue_number" => issue.number,
      "revision" => completion.revision,
      "state" => completion.state,
      "closed_by_actor" => completion.closed_by_actor,
      "criteria" => completion.criteria
    })
  end

  defp operator do
    %{
      actor_id: "user:treasury-operator",
      auth_method: "session",
      approval_receipt_ref: "approval:#{unique()}"
    }
  end

  defp price_attributes do
    %{
      buyer_ref: "buyer:openagents-treasury",
      amount_sats: @amount_sats,
      acceptance_criteria: [@criterion],
      verification_policy: %{
        "name" => "forge.qualification.v1",
        "requires" => ["accepted completion claim", "qualification receipt at the revision"]
      },
      destination_kind: "bolt12_offer",
      expires_at: DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)
    }
  end

  defp claimant(%{buyer: buyer}, completion) do
    %{
      claimant_ref: "user:#{buyer.id}",
      work_job_ref: "work-job:#{completion.assignment.work_job_id}",
      destination_kind: "bolt12_offer",
      destination: "lno1#{String.duplicate("q", 40)}"
    }
  end

  defp settlement_request(commit_sha) do
    %{
      commit_sha: commit_sha,
      idempotency_key: "settlement-#{unique()}",
      actor_id: "user:treasury-operator",
      auth_method: "session",
      approval_receipt_ref: "approval:#{unique()}"
    }
  end

  defp gateway_request(%{commit_sha: commit_sha}) do
    %{
      idempotency_key: "settlement-#{unique()}",
      amount_sats: @amount_sats,
      destination_kind: "bolt12_offer",
      destination: "lno1#{String.duplicate("q", 40)}",
      memo: "bounty proof commit #{commit_sha}"
    }
  end

  defp publish(repository, level),
    do: Application.put_env(:openagents, :forge_public_visibility, %{repository.name => level})

  defp restore(key, nil), do: Application.delete_env(:openagents, key)
  defp restore(key, value), do: Application.put_env(:openagents, key, value)

  defp unique, do: System.unique_integer([:positive, :monotonic])
end
