defmodule OpenAgents.SettlementTest do
  use OpenAgents.DataCase, async: false

  import OpenAgents.IssuesFixtures

  alias OpenAgents.Settlement

  alias OpenAgents.Settlement.{Adjustment, Claim, PaymentIntent, PaymentReceipt}

  defmodule Gateway do
    @moduledoc false
    @behaviour OpenAgents.Settlement.PaymentGateway

    @impl true
    def pay(request) do
      record(:pay)
      answer(:pay, request)
    end

    @impl true
    def lookup(idempotency_key) do
      record(:lookup)
      answer(:lookup, idempotency_key)
    end

    def calls(action) do
      Application.get_env(:openagents, :settlement_test_calls)
      |> Agent.get(&Map.get(&1, action, 0))
    end

    defp record(action) do
      Application.get_env(:openagents, :settlement_test_calls)
      |> Agent.update(&Map.update(&1, action, 1, fn count -> count + 1 end))
    end

    defp answer(action, argument) do
      answers = Application.fetch_env!(:openagents, :settlement_test_answers)
      answers.(action, argument)
    end
  end

  @preimage_digest String.duplicate("ab", 32)

  setup do
    counter = start_supervised!({Agent, fn -> %{} end})
    configured_visibility = Application.get_env(:openagents, :forge_public_visibility)
    Application.put_env(:openagents, :settlement_payment_gateway, Gateway)
    Application.put_env(:openagents, :settlement_test_calls, counter)
    answer_with(&settles/2)

    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Bounded bounty"})

    on_exit(fn ->
      Application.delete_env(:openagents, :settlement_payment_gateway)
      Application.delete_env(:openagents, :settlement_test_calls)
      Application.delete_env(:openagents, :settlement_test_answers)

      if configured_visibility,
        do: Application.put_env(:openagents, :forge_public_visibility, configured_visibility),
        else: Application.delete_env(:openagents, :forge_public_visibility)
    end)

    %{repository: repository, issue: issue}
  end

  describe "treasury policy" do
    test "pricing needs an admitted treasury policy", %{issue: issue} do
      assert {:error, :treasury_policy_missing} =
               Settlement.price_bounty(issue, price_attributes(), operator())
    end

    test "an admitted policy carries a digest over its exact rules" do
      assert {:ok, policy} = Settlement.admit_treasury_policy(operator())
      assert policy.policy_id == Settlement.policy_id()
      assert String.match?(policy.policy_digest, ~r/\A[0-9a-f]{64}\z/)
      assert policy.rules["custody"] == "claimant_self_custodial_destination"
    end

    test "a policy that makes verification optional is refused" do
      assert {:error, :verification_optional} =
               Settlement.admit_treasury_policy(operator(), %{
                 "requires_accepted_verification" => false
               })
    end

    test "a price above the treasury authority is refused", %{issue: issue} do
      {:ok, _policy} =
        Settlement.admit_treasury_policy(operator(), %{"max_payment_sats" => 5_000})

      assert {:error, :amount_exceeds_treasury_authority} =
               Settlement.price_bounty(issue, price_attributes(%{amount_sats: 5_001}), operator())
    end

    test "a destination kind outside the policy is refused", %{issue: issue} do
      {:ok, _policy} = Settlement.admit_treasury_policy(operator())

      assert {:error, :destination_kind_not_admitted} =
               Settlement.price_bounty(
                 issue,
                 price_attributes(%{destination_kind: "hosted_wallet"}),
                 operator()
               )
    end
  end

  describe "settlement" do
    test "a verified claim is paid once and keeps its exact receipt", %{issue: issue} do
      %{claim: claim, spec: spec} = verified_claim(issue)

      assert {:ok, settled} = Settlement.settle(claim, settlement_request())
      assert settled.claim.state == "paid"
      assert settled.intent.state == "paid"
      assert settled.intent.attempts == 1
      assert settled.receipt.amount_sats == spec.amount_sats
      assert settled.receipt.preimage_digest == @preimage_digest
      assert String.match?(settled.receipt.receipt_digest, ~r/\A[0-9a-f]{64}\z/)
      assert Gateway.calls(:pay) == 1
      assert Repo.aggregate(PaymentReceipt, :count) == 1
    end

    test "a duplicate request returns the first receipt without paying again", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)
      request = settlement_request()

      assert {:ok, first} = Settlement.settle(claim, request)
      assert {:ok, second} = Settlement.settle(claim, request)

      assert second.receipt.id == first.receipt.id
      assert Gateway.calls(:pay) == 1
      assert Repo.aggregate(PaymentReceipt, :count) == 1
    end

    test "a second idempotency key for a paid claim cannot pay again", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)
      assert {:ok, _settled} = Settlement.settle(claim, settlement_request())

      assert {:error, {:claim_not_settleable, "paid"}} =
               Settlement.settle(claim, settlement_request())

      assert Repo.aggregate(PaymentReceipt, :count) == 1
    end

    test "an idempotency key cannot be reused for another claim", %{issue: issue} do
      %{claim: first_claim} = verified_claim(issue)
      request = settlement_request()
      assert {:ok, _settled} = Settlement.settle(first_claim, request)

      other_issue = issue_fixture(Repo.preload(issue, :repository).repository, %{title: "Second"})
      %{claim: second_claim} = verified_claim(other_issue)

      assert {:error, :idempotency_key_conflict} =
               Settlement.settle(second_claim, %{request | commit_sha: commit_sha()})
    end

    test "a settlement without an approval reference is refused", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)
      request = Map.delete(settlement_request(), :approval_receipt_ref)

      assert {:error, :approval_missing} = Settlement.settle(claim, request)
      assert Gateway.calls(:pay) == 0
    end

    test "a repriced specification stops payment on the old claim", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)

      {:ok, _repriced} =
        Settlement.price_bounty(issue, price_attributes(%{amount_sats: 4_000}), operator())

      assert {:error, :spec_superseded} = Settlement.settle(claim, settlement_request())
      assert Gateway.calls(:pay) == 0
    end

    test "a claim pinned to a stale fingerprint stops payment", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)

      {1, nil} =
        Repo.update_all(
          from(record in Claim, where: record.id == ^claim.id),
          set: [spec_fingerprint: String.duplicate("cd", 32)]
        )

      assert {:error, :spec_fingerprint_mismatch} =
               Settlement.settle(claim, settlement_request())
    end

    test "a rejected verifier stops payment", %{issue: issue} do
      %{claim: claim} = claimed_bounty(issue)

      assert {:ok, verification} =
               Settlement.verify_claim(
                 claim,
                 verification_attributes(%{outcome: "rejected", reason_code: "criteria_unmet"})
               )

      assert verification.outcome == "rejected"
      assert Repo.get!(Claim, claim.id).state == "rejected"

      assert {:error, {:claim_not_settleable, "rejected"}} =
               Settlement.settle(
                 claim,
                 settlement_request(%{commit_sha: verification.commit_sha})
               )

      assert Gateway.calls(:pay) == 0
    end

    test "a commit without its own verification stops payment", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)

      assert {:error, :stale_commit} =
               Settlement.settle(claim, settlement_request(%{commit_sha: commit_sha()}))

      assert Gateway.calls(:pay) == 0
    end

    test "a claim without any verification stops payment", %{issue: issue} do
      %{claim: claim} = claimed_bounty(issue)

      assert {:error, :verification_missing} = Settlement.settle(claim, settlement_request())
    end

    test "a verification against a different work job is refused", %{issue: issue} do
      %{claim: claim} = claimed_bounty(issue)

      assert {:error, :work_job_mismatch} =
               Settlement.verify_claim(
                 claim,
                 verification_attributes(%{work_job_ref: "work-job:other"})
               )
    end

    test "a verification under a different policy digest is refused", %{issue: issue} do
      %{claim: claim} = claimed_bounty(issue)

      assert {:error, :verifier_policy_mismatch} =
               Settlement.verify_claim(
                 claim,
                 verification_attributes(%{verifier_policy_digest: String.duplicate("ef", 32)})
               )
    end

    test "the treasury daily budget bounds settlement", %{issue: issue} do
      %{claim: claim} =
        verified_claim(issue, %{
          rules: %{"max_payment_sats" => 3_000, "daily_budget_sats" => 3_000},
          price: %{amount_sats: 3_000}
        })

      assert {:ok, _settled} = Settlement.settle(claim, settlement_request())

      second_issue = issue_fixture(Repo.preload(issue, :repository).repository, %{title: "Next"})

      {:ok, spec} =
        Settlement.price_bounty(second_issue, price_attributes(%{amount_sats: 3_000}), operator())

      {:ok, second_claim} = Settlement.claim_bounty(spec, claimant())

      {:ok, verification} =
        Settlement.verify_claim(second_claim, verification_attributes(%{work_job_ref: nil}))

      assert {:error, :daily_budget_exhausted} =
               Settlement.settle(
                 second_claim,
                 settlement_request(%{commit_sha: verification.commit_sha})
               )
    end
  end

  describe "payment failure and reconciliation" do
    test "a failed payment retries under the same key and pays once", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)
      request = settlement_request()
      answer_with(fn :pay, _request -> {:error, "route_not_found"} end)

      assert {:error, {:payment_failed, "route_not_found"}} = Settlement.settle(claim, request)

      assert Repo.get_by!(PaymentIntent, idempotency_key: request.idempotency_key).state ==
               "failed"

      answer_with(&settles/2)

      assert {:ok, settled} = Settlement.settle(claim, request)
      assert settled.intent.attempts == 2
      assert Repo.aggregate(PaymentReceipt, :count) == 1
    end

    test "retries stop at the policy attempt bound", %{issue: issue} do
      %{claim: claim} = verified_claim(issue, %{rules: %{"max_attempts" => 1}})
      request = settlement_request()
      answer_with(fn :pay, _request -> {:error, "route_not_found"} end)

      assert {:error, {:payment_failed, "route_not_found"}} = Settlement.settle(claim, request)

      assert {:error, :payment_attempts_exhausted} = Settlement.settle(claim, request)
      assert Gateway.calls(:pay) == 1
    end

    test "a lost acknowledgement reconciles into one payment", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)
      request = settlement_request()

      answer_with(fn
        :pay, _request -> {:pending, "acknowledgement_missing"}
        :lookup, _key -> settled_evidence()
      end)

      assert {:pending, intent} = Settlement.settle(claim, request)
      assert intent.state == "pending"
      assert Repo.aggregate(PaymentReceipt, :count) == 0

      assert {:ok, settled} = Settlement.reconcile(request.idempotency_key)
      assert settled.claim.state == "paid"
      assert Gateway.calls(:pay) == 1
      assert Repo.aggregate(PaymentReceipt, :count) == 1

      assert {:ok, again} = Settlement.reconcile(request.idempotency_key)
      assert again.receipt.id == settled.receipt.id
      assert Gateway.calls(:pay) == 1
    end

    test "an unknown key stays unpaid", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)
      request = settlement_request()

      answer_with(fn
        :pay, _request -> {:pending, "acknowledgement_missing"}
        :lookup, _key -> {:unknown, nil}
      end)

      assert {:pending, _intent} = Settlement.settle(claim, request)
      assert {:error, :payment_unsettled} = Settlement.reconcile(request.idempotency_key)
      assert Repo.aggregate(PaymentReceipt, :count) == 0
    end

    test "reconciling an unknown intent reports the missing intent" do
      assert {:error, :payment_intent_missing} = Settlement.reconcile("no-such-key-000000")
    end

    test "an unconfigured gateway fails closed", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)
      Application.delete_env(:openagents, :settlement_payment_gateway)

      assert {:error, {:payment_failed, "payment_gateway_unconfigured"}} =
               Settlement.settle(claim, settlement_request())

      assert Repo.aggregate(PaymentReceipt, :count) == 0
    end
  end

  describe "expiry, dispute, and refund" do
    test "an expired claim releases the specification and never pays", %{issue: issue} do
      %{claim: claim, spec: spec} = verified_claim(issue)

      assert {:ok, adjustment} = Settlement.expire_claim(claim, operator(), "claim_window_passed")
      assert adjustment.kind == "expiry"
      assert Repo.get!(Claim, claim.id).state == "expired"

      assert {:error, {:claim_not_settleable, "expired"}} =
               Settlement.settle(claim, settlement_request())

      assert {:ok, replacement} = Settlement.claim_bounty(spec, claimant())
      assert replacement.id != claim.id
    end

    test "a claim past its expiry cannot be verified or paid", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {1, nil} =
        Repo.update_all(from(record in Claim, where: record.id == ^claim.id),
          set: [expires_at: past]
        )

      assert {:error, :claim_expired} = Settlement.settle(claim, settlement_request())

      assert {:error, :claim_expired} =
               Settlement.verify_claim(claim, verification_attributes(%{work_job_ref: nil}))
    end

    test "a dispute freezes settlement", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)

      assert {:ok, adjustment} = Settlement.open_dispute(claim, operator(), "buyer_contested")
      assert adjustment.kind == "dispute"

      assert {:error, {:claim_not_settleable, "disputed"}} =
               Settlement.settle(claim, settlement_request())

      assert Gateway.calls(:pay) == 0
    end

    test "a refund is appended without rewriting the payment receipt", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)
      {:ok, settled} = Settlement.settle(claim, settlement_request())

      assert {:ok, adjustment} = Settlement.refund(claim, operator(), "buyer_withdrew")
      assert adjustment.kind == "refund"
      assert Repo.get!(Claim, claim.id).state == "refunded"

      receipt = Repo.get!(PaymentReceipt, settled.receipt.id)
      assert receipt.receipt_digest == settled.receipt.receipt_digest
      assert receipt.payment_hash == settled.receipt.payment_hash
      assert Repo.aggregate(Adjustment, :count) == 1
    end

    test "an unpaid claim cannot be refunded", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)

      assert {:error, {:claim_not_paid, "verified"}} =
               Settlement.refund(claim, operator(), "buyer_withdrew")
    end
  end

  describe "public projection" do
    test "a dark repository publishes nothing", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)
      {:ok, _settled} = Settlement.settle(claim, settlement_request())

      assert Settlement.public_projection(issue) == nil
    end

    test "the pulse level publishes bounded amount and status only", %{
      issue: issue,
      repository: repository
    } do
      %{claim: claim} = verified_claim(issue)
      {:ok, _settled} = Settlement.settle(claim, settlement_request())
      publish(repository, :l1)

      projection = Settlement.public_projection(issue)

      assert projection["amount_sats"] == 2_500
      assert projection["state"] == "paid"
      assert projection["paid"] == true
      assert projection["buyer_kind"] == "buyer"
      assert projection["claimant_kind"] == "agent"
      refute Map.has_key?(projection, "spec_fingerprint")
      refute Map.has_key?(projection, "commit_sha")
      refute_private(projection)
    end

    test "the ledger level publishes the evidence chain without private facts", %{
      issue: issue,
      repository: repository
    } do
      %{claim: claim, verification: verification} = verified_claim(issue)
      {:ok, settled} = Settlement.settle(claim, settlement_request())
      publish(repository, :l2)

      projection = Settlement.public_projection(issue)

      assert projection["commit_sha"] == verification.commit_sha
      assert projection["payment_hash"] == settled.receipt.payment_hash
      assert projection["receipt_digest"] == settled.receipt.receipt_digest
      assert projection["verifier_kind"] == "verifier"
      refute_private(projection)
    end

    test "an unpriced issue publishes nothing", %{issue: issue, repository: repository} do
      publish(repository, :l2)
      assert Settlement.public_projection(issue) == nil
    end
  end

  describe "receipt export" do
    test "the claimant exports a receipt that needs no hosted wallet", %{issue: issue} do
      %{claim: claim, verification: verification} = verified_claim(issue)
      {:ok, settled} = Settlement.settle(claim, settlement_request())

      assert {:ok, export} = Settlement.export_payment_receipt(claim, claim.claimant_ref)

      assert export["amount_sats"] == 2_500
      assert export["destination"] == claim.destination
      assert export["destination_kind"] == "bolt12_offer"
      assert export["commit_sha"] == verification.commit_sha
      assert export["payment_hash"] == settled.receipt.payment_hash
      assert export["receipt_digest"] == settled.receipt.receipt_digest
      refute Map.has_key?(export, "actor_id")
      refute Map.has_key?(export, "approval_receipt_ref")
      refute Map.has_key?(export, "gateway_ref")
    end

    test "another claimant cannot export the receipt", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)
      {:ok, _settled} = Settlement.settle(claim, settlement_request())

      assert {:error, :not_the_claimant} =
               Settlement.export_payment_receipt(claim, "agent:someone-else")
    end

    test "an unpaid claim has no receipt to export", %{issue: issue} do
      %{claim: claim} = verified_claim(issue)

      assert {:error, :payment_receipt_missing} =
               Settlement.export_payment_receipt(claim, claim.claimant_ref)
    end
  end

  describe "claim admission" do
    test "only one live claim holds a specification", %{issue: issue} do
      %{spec: spec} = claimed_bounty(issue)

      assert {:error, changeset} = Settlement.claim_bounty(spec, claimant())
      assert "has already been taken" in errors_on(changeset).bounty_spec_id
    end

    test "a destination outside the policy is refused", %{issue: issue} do
      {:ok, _policy} = Settlement.admit_treasury_policy(operator())
      {:ok, spec} = Settlement.price_bounty(issue, price_attributes(), operator())

      assert {:error, :destination_kind_not_admitted} =
               Settlement.claim_bounty(spec, claimant(%{destination_kind: "hosted_wallet"}))
    end

    test "a superseded specification cannot be claimed", %{issue: issue} do
      {:ok, _policy} = Settlement.admit_treasury_policy(operator())
      {:ok, spec} = Settlement.price_bounty(issue, price_attributes(), operator())

      {:ok, repriced} =
        Settlement.price_bounty(issue, price_attributes(%{amount_sats: 1_500}), operator())

      assert {:error, :spec_superseded} = Settlement.claim_bounty(spec, claimant())
      assert {:ok, _claim} = Settlement.claim_bounty(repriced, claimant())
    end

    test "a claim records the destination digest, never a treasury wallet", %{issue: issue} do
      %{claim: claim} = claimed_bounty(issue)

      assert String.match?(claim.destination_digest, ~r/\A[0-9a-f]{64}\z/)
      assert claim.destination_kind == "bolt12_offer"
      assert claim.state == "claimed"
    end
  end

  defp verified_claim(issue, options \\ %{}) do
    %{claim: claim, spec: spec} = claimed_bounty(issue, options)

    {:ok, verification} =
      Settlement.verify_claim(claim, verification_attributes(%{commit_sha: default_commit_sha()}))

    %{claim: Repo.get!(Claim, claim.id), spec: spec, verification: verification}
  end

  defp claimed_bounty(issue, options \\ %{}) do
    {:ok, _policy} =
      case Settlement.treasury_policy() do
        {:ok, policy} -> {:ok, policy}
        {:error, :treasury_policy_missing} -> admit(Map.get(options, :rules, %{}))
      end

    {:ok, spec} =
      Settlement.price_bounty(
        issue,
        price_attributes(Map.get(options, :price, %{})),
        operator()
      )

    {:ok, claim} = Settlement.claim_bounty(spec, claimant())
    %{claim: claim, spec: spec}
  end

  defp admit(rules), do: Settlement.admit_treasury_policy(operator(), rules)

  defp operator do
    %{
      actor_id: "user:treasury-operator",
      auth_method: "session",
      approval_receipt_ref: "approval:#{unique()}"
    }
  end

  defp claimant(overrides \\ %{}) do
    Map.merge(
      %{
        claimant_ref: "agent:claimant-#{unique()}",
        work_job_ref: "work-job:#{unique()}",
        destination_kind: "bolt12_offer",
        destination: "lno1#{String.duplicate("q", 40)}"
      },
      overrides
    )
  end

  defp price_attributes(overrides \\ %{}) do
    Map.merge(
      %{
        buyer_ref: "buyer:openagents-treasury",
        amount_sats: 2_500,
        acceptance_criteria: ["The test suite passes.", "The receipt chain is exportable."],
        verification_policy: %{
          "name" => "forge.precommit.v1",
          "requires" => ["mix precommit", "reviewer decision"]
        },
        destination_kind: "bolt12_offer",
        expires_at: DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)
      },
      overrides
    )
  end

  defp verification_attributes(overrides) do
    %{
      commit_sha: default_commit_sha(),
      verifier_ref: "verifier:forge-precommit",
      evidence_digest: String.duplicate("1a", 32),
      outcome: "accepted",
      reason_code: "criteria_met",
      auth_method: "session",
      decision_receipt_ref: "decision:#{unique()}"
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp settlement_request(overrides \\ %{}) do
    Map.merge(
      %{
        commit_sha: default_commit_sha(),
        idempotency_key: "settlement-#{unique()}",
        actor_id: "user:treasury-operator",
        auth_method: "session",
        approval_receipt_ref: "approval:#{unique()}"
      },
      overrides
    )
  end

  defp settles(:pay, _request), do: settled_evidence()
  defp settles(:lookup, _key), do: {:unknown, nil}

  defp settled_evidence do
    {:ok,
     %{
       payment_hash: String.duplicate("0", 63) <> "1",
       preimage_digest: @preimage_digest,
       fee_sats: 3,
       paid_at: DateTime.utc_now(),
       gateway_ref: "treasury-node:payment-1"
     }}
  end

  defp answer_with(answers),
    do: Application.put_env(:openagents, :settlement_test_answers, answers)

  defp publish(repository, level),
    do: Application.put_env(:openagents, :forge_public_visibility, %{repository.name => level})

  defp refute_private(projection) do
    refute Map.has_key?(projection, "destination")
    refute Map.has_key?(projection, "destination_digest")
    refute Map.has_key?(projection, "claimant_ref")
    refute Map.has_key?(projection, "buyer_ref")
    refute Map.has_key?(projection, "work_job_ref")
    refute Map.has_key?(projection, "actor_id")
    refute Map.has_key?(projection, "approval_receipt_ref")
    refute Map.has_key?(projection, "gateway_ref")
    refute Map.has_key?(projection, "preimage_digest")
  end

  defp default_commit_sha, do: String.duplicate("a", 40)

  defp commit_sha do
    unique()
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(40, "b")
  end

  defp unique, do: System.unique_integer([:positive, :monotonic])
end
