defmodule OpenAgents.Settlement.ConstraintsTest do
  @moduledoc """
  SETTLEMENT-001, at the database. Every claim here bypasses the Ecto changeset
  and writes raw SQL, because the property is that PostgreSQL refuses the row —
  not that the application declines to build it.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.IssuesFixtures

  alias OpenAgents.Repo

  @insert_policy """
  INSERT INTO settlement_treasury_policies
    (id, policy_id, version, policy_digest, rules, actor_id, auth_method,
     approval_receipt_ref, inserted_at)
  VALUES ($1, $2, 1, $3, $4, $5, $6, $7, $8)
  """

  @insert_spec """
  INSERT INTO settlement_bounty_specs
    (id, treasury_policy_id, issue_id, revision, buyer_ref, amount_sats,
     acceptance_criteria, verification_policy, destination_kind, expires_at,
     spec_fingerprint, actor_id, auth_method, approval_receipt_ref, inserted_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
  """

  @insert_claim """
  INSERT INTO settlement_claims
    (id, bounty_spec_id, spec_fingerprint, claimant_ref, work_job_ref,
     destination_kind, destination, destination_digest, state, claim_digest,
     expires_at, inserted_at, updated_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $12)
  """

  @insert_verification """
  INSERT INTO settlement_verifications
    (id, claim_id, spec_fingerprint, commit_sha, work_job_ref, verifier_ref,
     verifier_policy_digest, evidence_digest, outcome, reason_code, auth_method,
     decision_receipt_ref, inserted_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
  """

  @insert_intent """
  INSERT INTO settlement_payment_intents
    (id, claim_id, verification_id, idempotency_key, amount_sats, commit_sha,
     destination_digest, spec_fingerprint, state, attempts, intent_digest,
     actor_id, auth_method, approval_receipt_ref, inserted_at, updated_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $15)
  """

  @insert_receipt """
  INSERT INTO settlement_payment_receipts
    (id, payment_intent_id, claim_id, amount_sats, fee_sats, payment_hash,
     preimage_digest, gateway_ref, paid_at, receipt_digest, inserted_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
  """

  setup do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Settlement constraint test"})
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, 900, :second)

    policy = insert_policy!(now)
    spec = insert_spec!(issue.id, policy.id, 1, now, expires_at)
    claim = insert_claim!(spec, now, expires_at)
    verification = insert_verification!(claim, now)

    %{
      issue: issue,
      policy: policy,
      spec: spec,
      claim: claim,
      verification: verification,
      now: now,
      expires_at: expires_at
    }
  end

  describe "payment receipt uniqueness" do
    test "a payment hash cannot be reused for another receipt", context do
      intent_1_id = Ecto.UUID.generate()
      payment_hash = hex64()

      assert {:ok, %{num_rows: 1}} =
               insert_intent(intent_1_id, context, "intent-#{unique()}", "paid")

      assert {:ok, %{num_rows: 1}} =
               insert_receipt(
                 Ecto.UUID.generate(),
                 intent_1_id,
                 context.claim.id,
                 payment_hash,
                 context.now
               )

      second =
        insert_issue_chain!(
          context.issue.id,
          context.policy.id,
          2,
          context.now,
          context.expires_at
        )
        |> Map.put(:now, context.now)

      intent_2_id = Ecto.UUID.generate()

      assert {:ok, %{num_rows: 1}} =
               insert_intent(intent_2_id, second, "intent-#{unique()}", "paid")

      assert {:error, %Postgrex.Error{} = error} =
               insert_receipt(
                 Ecto.UUID.generate(),
                 intent_2_id,
                 second.claim.id,
                 payment_hash,
                 context.now
               )

      assert error.postgres.constraint ==
               "settlement_payment_receipts_payment_hash_index"
    end

    test "a second receipt for one payment intent is refused", context do
      intent_id = Ecto.UUID.generate()
      first_hash = hex64()
      second_hash = hex64()

      assert {:ok, %{num_rows: 1}} =
               insert_intent(intent_id, context, "intent-#{unique()}", "paid")

      assert {:ok, %{num_rows: 1}} =
               insert_receipt(
                 Ecto.UUID.generate(),
                 intent_id,
                 context.claim.id,
                 first_hash,
                 context.now
               )

      assert {:error, %Postgrex.Error{} = error} =
               insert_receipt(
                 Ecto.UUID.generate(),
                 intent_id,
                 context.claim.id,
                 second_hash,
                 context.now
               )

      assert error.postgres.constraint ==
               "settlement_payment_receipts_payment_intent_id_index"
    end
  end

  describe "payment intent partial uniqueness" do
    test "two paid intents for one claim are refused", context do
      first_id = Ecto.UUID.generate()

      assert {:ok, %{num_rows: 1}} =
               insert_intent(first_id, context, "intent-#{unique()}", "paid")

      second_id = Ecto.UUID.generate()

      assert {:error, %Postgrex.Error{} = error} =
               insert_intent(second_id, context, "intent-#{unique()}", "paid")

      assert error.postgres.constraint == "settlement_payment_intent_single_paid"
    end
  end

  defp insert_policy!(now) do
    id = Ecto.UUID.generate()

    Repo.query!(@insert_policy, [
      uuid(id),
      "policy:#{unique()}",
      hex64(),
      %{"max_payment_sats" => 100_000, "daily_budget_sats" => 1_000_000},
      "actor:operator",
      "session",
      "approval:#{unique()}",
      now
    ])

    %{id: id}
  end

  defp insert_spec!(issue_id, policy_id, revision, now, expires_at) do
    id = Ecto.UUID.generate()
    fingerprint = hex64()

    Repo.query!(@insert_spec, [
      uuid(id),
      uuid(policy_id),
      issue_id,
      revision,
      "buyer:openagents",
      2_500,
      ["The constraint holds."],
      %{"name" => "forge.precommit.v1", "requires" => ["mix precommit"]},
      "bolt12_offer",
      expires_at,
      fingerprint,
      "actor:operator",
      "session",
      "approval:#{unique()}",
      now
    ])

    %{id: id, spec_fingerprint: fingerprint}
  end

  defp insert_claim!(spec, now, expires_at) do
    id = Ecto.UUID.generate()
    destination_digest = hex64()
    fingerprint = spec.spec_fingerprint

    Repo.query!(@insert_claim, [
      uuid(id),
      uuid(spec.id),
      fingerprint,
      "agent:claimant-#{unique()}",
      "work-job:#{unique()}",
      "bolt12_offer",
      "lno1#{String.duplicate("q", 40)}",
      destination_digest,
      "verified",
      hex64(),
      expires_at,
      now
    ])

    %{id: id, spec_fingerprint: fingerprint, destination_digest: destination_digest}
  end

  defp insert_verification!(claim, now) do
    id = Ecto.UUID.generate()
    commit_sha = hex40()

    Repo.query!(@insert_verification, [
      uuid(id),
      uuid(claim.id),
      claim.spec_fingerprint,
      commit_sha,
      "work-job:#{unique()}",
      "verifier:forge-precommit",
      hex64(),
      hex64(),
      "accepted",
      "criteria_met",
      "session",
      "decision:#{unique()}",
      now
    ])

    %{id: id, commit_sha: commit_sha}
  end

  defp insert_issue_chain!(issue_id, policy_id, revision, now, expires_at) do
    spec = insert_spec!(issue_id, policy_id, revision, now, expires_at)
    claim = insert_claim!(spec, now, expires_at)
    verification = insert_verification!(claim, now)

    %{spec: spec, claim: claim, verification: verification}
  end

  defp insert_intent(intent_id, context, idempotency_key, state) do
    Repo.query(@insert_intent, [
      uuid(intent_id),
      uuid(context.claim.id),
      uuid(context.verification.id),
      idempotency_key,
      2_500,
      context.verification.commit_sha,
      context.claim.destination_digest,
      context.spec.spec_fingerprint,
      state,
      0,
      hex64(),
      "actor:operator",
      "session",
      "approval:#{unique()}",
      context.now
    ])
  end

  defp insert_receipt(receipt_id, payment_intent_id, claim_id, payment_hash, now) do
    Repo.query(@insert_receipt, [
      uuid(receipt_id),
      uuid(payment_intent_id),
      uuid(claim_id),
      2_500,
      3,
      payment_hash,
      hex64(),
      "gateway:#{unique()}",
      now,
      hex64(),
      now
    ])
  end

  defp hex40, do: Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
  defp hex64, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
  defp unique, do: System.unique_integer([:positive, :monotonic])
  defp uuid(value), do: Ecto.UUID.dump!(value)
end
