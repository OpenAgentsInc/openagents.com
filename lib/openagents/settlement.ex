defmodule OpenAgents.Settlement do
  @moduledoc """
  Bounty settlement: price a forge issue, claim it, verify the delivery, and pay
  the claimant from the treasury against an inspectable receipt chain.

  The domain owns authority and evidence, never custody. Every payment needs an
  operator-admitted treasury policy, an approval reference, a specification
  fingerprint that has not moved, an accepted verification at the exact commit,
  and an idempotency key. The configured payment gateway
  (`OpenAgents.Settlement.PaymentGateway`) performs the transfer to a
  self-custodial destination and returns exact evidence.

  A specification change, a failed verifier, a stale commit, a missing
  approval, an exhausted budget, an expired claim, a dispute, or a duplicate
  request each stop a payment. A lost acknowledgement reconciles through the
  same idempotency key, so it never becomes a second payment.
  """

  import Ecto.Query

  alias OpenAgents.Forge.Visibility
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  alias OpenAgents.Settlement.{
    Adjustment,
    BountySpec,
    Claim,
    PaymentGateway,
    PaymentIntent,
    PaymentReceipt,
    TreasuryPolicy,
    Verification
  }

  @policy_id "openagents.settlement.bounty.v1"
  @policy_version 1

  @default_rules %{
    "unit" => "sat",
    "custody" => "claimant_self_custodial_destination",
    "destination_kinds" => ["bolt12_offer"],
    "max_payment_sats" => 10_000,
    "daily_budget_sats" => 50_000,
    "max_attempts" => 3,
    "requires_accepted_verification" => true,
    "requires_approval_receipt" => true,
    "expiry" => "an expired claim releases the specification and never pays",
    "failed_payment" => "the same idempotency key retries until max_attempts",
    "lost_acknowledgement" => "reconcile the idempotency key, never pay twice",
    "dispute" => "a dispute freezes settlement until an operator resolves it",
    "refund" => "a refund is an append-only adjustment, never a receipt rewrite"
  }

  @doc "The settlement policy identifier."
  def policy_id, do: @policy_id

  @doc "The default treasury rules an operator can narrow before admission."
  def default_rules, do: @default_rules

  @doc """
  Admits the treasury policy that bounds every later payment.

  `operator` carries `actor_id`, `auth_method`, and `approval_receipt_ref`.
  """
  @spec admit_treasury_policy(map(), map()) :: {:ok, TreasuryPolicy.t()} | {:error, term()}
  def admit_treasury_policy(operator, rules \\ %{}) do
    rules = Map.merge(@default_rules, rules)

    with :ok <- validate_operator(operator),
         :ok <- validate_rules(rules) do
      digest =
        Canonical.digest!(%{
          "policy_id" => @policy_id,
          "version" => @policy_version,
          "rules" => rules
        })

      %TreasuryPolicy{}
      |> TreasuryPolicy.changeset(%{
        policy_id: @policy_id,
        version: @policy_version,
        policy_digest: digest,
        rules: rules,
        actor_id: operator.actor_id,
        auth_method: operator.auth_method,
        approval_receipt_ref: operator.approval_receipt_ref
      })
      |> Repo.insert()
    end
  end

  @doc "The admitted treasury policy, or `{:error, :treasury_policy_missing}`."
  @spec treasury_policy() :: {:ok, TreasuryPolicy.t()} | {:error, :treasury_policy_missing}
  def treasury_policy do
    case Repo.get_by(TreasuryPolicy, policy_id: @policy_id, version: @policy_version) do
      %TreasuryPolicy{} = policy -> {:ok, policy}
      nil -> {:error, :treasury_policy_missing}
    end
  end

  @doc """
  Prices one issue and fingerprints the specification.

  Repricing the same issue appends a revision with a new fingerprint. Claims
  pinned to the previous fingerprint can no longer be paid.
  """
  @spec price_bounty(Issue.t(), map(), map()) :: {:ok, BountySpec.t()} | {:error, term()}
  def price_bounty(%Issue{} = issue, attributes, operator) do
    with :ok <- validate_operator(operator),
         {:ok, policy} <- treasury_policy(),
         {:ok, priced} <- validate_price(policy, attributes) do
      revision = next_revision(issue)

      fingerprint =
        Canonical.digest!(%{
          "policy_digest" => policy.policy_digest,
          "issue_id" => issue.id,
          "revision" => revision,
          "buyer_ref" => priced.buyer_ref,
          "amount_sats" => priced.amount_sats,
          "acceptance_criteria" => priced.acceptance_criteria,
          "verification_policy" => priced.verification_policy,
          "destination_kind" => priced.destination_kind,
          "expires_at" => DateTime.to_iso8601(priced.expires_at)
        })

      %BountySpec{}
      |> BountySpec.changeset(%{
        treasury_policy_id: policy.id,
        issue_id: issue.id,
        revision: revision,
        buyer_ref: priced.buyer_ref,
        amount_sats: priced.amount_sats,
        acceptance_criteria: priced.acceptance_criteria,
        verification_policy: priced.verification_policy,
        destination_kind: priced.destination_kind,
        expires_at: priced.expires_at,
        spec_fingerprint: fingerprint,
        actor_id: operator.actor_id,
        auth_method: operator.auth_method,
        approval_receipt_ref: operator.approval_receipt_ref
      })
      |> Repo.insert()
    end
  end

  @doc "The current priced specification for an issue, or nil."
  @spec current_spec(Issue.t()) :: BountySpec.t() | nil
  def current_spec(%Issue{} = issue) do
    BountySpec
    |> where(issue_id: ^issue.id)
    |> order_by(desc: :revision)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Claims the current specification and pins its fingerprint.

  `claimant` carries `claimant_ref`, `work_job_ref`, `destination_kind`, and
  `destination`. The destination is the claimant's own; the settlement never
  creates or holds a wallet for them.
  """
  @spec claim_bounty(BountySpec.t(), map()) :: {:ok, Claim.t()} | {:error, term()}
  def claim_bounty(%BountySpec{} = spec, claimant) do
    with {:ok, policy} <- treasury_policy(),
         :ok <- require_current_spec(spec),
         :ok <- require_unexpired_spec(spec),
         {:ok, destination} <- validate_destination(policy, spec, claimant),
         {:ok, refs} <- validate_claimant(claimant) do
      digest =
        Canonical.digest!(%{
          "spec_fingerprint" => spec.spec_fingerprint,
          "claimant_ref" => refs.claimant_ref,
          "work_job_ref" => refs.work_job_ref,
          "destination_digest" => destination.digest
        })

      %Claim{}
      |> Claim.changeset(%{
        bounty_spec_id: spec.id,
        spec_fingerprint: spec.spec_fingerprint,
        claimant_ref: refs.claimant_ref,
        work_job_ref: refs.work_job_ref,
        destination_kind: destination.kind,
        destination: destination.value,
        destination_digest: destination.digest,
        state: "claimed",
        claim_digest: digest,
        expires_at: spec.expires_at
      })
      |> Repo.insert()
    end
  end

  @doc """
  Records the qualification receipt for one claim at one exact commit.

  An accepted verification moves the claim to `verified`; a rejected one moves
  it to `rejected` and releases the specification for another claimant.
  """
  @spec verify_claim(Claim.t(), map()) :: {:ok, Verification.t()} | {:error, term()}
  def verify_claim(%Claim{} = claim, attributes) do
    with {:ok, claim} <- reload_claim(claim),
         {:ok, spec} <- claim_spec(claim),
         :ok <- require_settleable_claim(claim),
         :ok <- require_pinned_fingerprint(claim, spec),
         :ok <- require_unexpired_claim(claim),
         {:ok, decision} <- validate_verification(claim, spec, attributes) do
      Repo.transaction(fn ->
        verification =
          %Verification{}
          |> Verification.changeset(%{
            claim_id: claim.id,
            spec_fingerprint: spec.spec_fingerprint,
            commit_sha: decision.commit_sha,
            work_job_ref: claim.work_job_ref,
            verifier_ref: decision.verifier_ref,
            verifier_policy_digest: decision.verifier_policy_digest,
            evidence_digest: decision.evidence_digest,
            outcome: decision.outcome,
            reason_code: decision.reason_code,
            auth_method: decision.auth_method,
            decision_receipt_ref: decision.decision_receipt_ref
          })
          |> Repo.insert()
          |> or_rollback()

        claim_state = if decision.outcome == "accepted", do: "verified", else: "rejected"

        claim
        |> Claim.state_changeset(claim_state)
        |> Repo.update()
        |> or_rollback()

        verification
      end)
      |> transaction_result()
    end
  end

  @doc """
  Settles a verified claim from the treasury, once.

  `request` carries `commit_sha`, `idempotency_key`, `actor_id`, `auth_method`,
  and `approval_receipt_ref`. A duplicate request with the same key returns the
  original receipt without paying again.
  """
  @spec settle(Claim.t(), map()) ::
          {:ok, %{claim: Claim.t(), intent: PaymentIntent.t(), receipt: PaymentReceipt.t()}}
          | {:pending, PaymentIntent.t()}
          | {:error, term()}
  def settle(%Claim{} = claim, request) do
    with {:ok, operator} <- validate_settlement_request(request),
         {:ok, claim} <- reload_claim(claim),
         {:ok, prior} <- prior_intent(claim, operator.idempotency_key) do
      case prior do
        %PaymentIntent{state: "paid"} = intent -> settled_intent(intent)
        _open -> authorize(claim, operator)
      end
    end
  end

  defp prior_intent(%Claim{} = claim, idempotency_key) do
    case Repo.get_by(PaymentIntent, idempotency_key: idempotency_key) do
      nil -> {:ok, nil}
      %PaymentIntent{claim_id: claim_id} = intent when claim_id == claim.id -> {:ok, intent}
      %PaymentIntent{} -> {:error, :idempotency_key_conflict}
    end
  end

  defp settled_intent(%PaymentIntent{} = intent) do
    case receipt_for(intent) do
      %PaymentReceipt{} = receipt -> settled_result(intent, receipt)
      nil -> reconcile_open(intent)
    end
  end

  defp authorize(%Claim{} = claim, operator) do
    with {:ok, spec} <- claim_spec(claim),
         {:ok, policy} <- treasury_policy(),
         :ok <- require_settleable_claim(claim),
         :ok <- require_pinned_fingerprint(claim, spec),
         :ok <- require_current_spec(spec),
         :ok <- require_unexpired_claim(claim),
         {:ok, verification} <- accepted_verification(claim, operator.commit_sha, spec),
         :ok <- require_payment_authority(policy, spec),
         {:ok, intent} <- payment_intent(claim, spec, verification, operator) do
      dispatch(claim, spec, policy, intent)
    end
  end

  @doc """
  Reconciles one dispatched idempotency key against the gateway.

  A settled key that never acknowledged becomes its receipt here. A key the
  gateway does not know stays unpaid.
  """
  @spec reconcile(String.t()) ::
          {:ok, %{claim: Claim.t(), intent: PaymentIntent.t(), receipt: PaymentReceipt.t()}}
          | {:pending, PaymentIntent.t()}
          | {:error, term()}
  def reconcile(idempotency_key) when is_binary(idempotency_key) do
    case Repo.get_by(PaymentIntent, idempotency_key: idempotency_key) do
      nil -> {:error, :payment_intent_missing}
      %PaymentIntent{} = intent -> settled_intent(intent)
    end
  end

  @doc "Expires a live claim and releases the specification."
  @spec expire_claim(Claim.t(), map(), String.t()) :: {:ok, Adjustment.t()} | {:error, term()}
  def expire_claim(%Claim{} = claim, operator, reason_code),
    do: adjust(claim, operator, "expiry", reason_code, "expired")

  @doc "Freezes settlement for a claim under dispute."
  @spec open_dispute(Claim.t(), map(), String.t()) :: {:ok, Adjustment.t()} | {:error, term()}
  def open_dispute(%Claim{} = claim, operator, reason_code),
    do: adjust(claim, operator, "dispute", reason_code, "disputed")

  @doc "Records a refund for a paid claim without rewriting its receipt."
  @spec refund(Claim.t(), map(), String.t()) :: {:ok, Adjustment.t()} | {:error, term()}
  def refund(%Claim{} = claim, operator, reason_code) do
    with {:ok, claim} <- reload_claim(claim),
         :ok <- require_paid_claim(claim) do
      adjust(claim, operator, "refund", reason_code, "refunded")
    end
  end

  @doc """
  The public projection for an issue's settlement, bounded by the repository's
  disclosure level (TRANSPARENCY-001).

  Returns nil when the repository publishes nothing, when the level is below
  `:l1`, or when the issue has no priced specification.
  """
  @spec public_projection(Issue.t()) :: map() | nil
  def public_projection(%Issue{} = issue) do
    issue = Repo.preload(issue, :repository)
    level = Visibility.level(issue.repository && issue.repository.name)

    case {level, current_spec(issue)} do
      {:l0, _spec} -> nil
      {_level, nil} -> nil
      {level, spec} -> projection(issue, spec, level)
    end
  end

  @doc """
  The claimant's exportable payment receipt.

  The export carries the claimant's own destination and the evidence chain that
  proves the payment. It never carries operator identity, approval references,
  or gateway credentials, and it does not depend on a hosted wallet.
  """
  @spec export_payment_receipt(Claim.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def export_payment_receipt(%Claim{} = claim, claimant_ref) when is_binary(claimant_ref) do
    with {:ok, claim} <- reload_claim(claim),
         :ok <- require_claimant(claim, claimant_ref),
         {:ok, spec} <- claim_spec(claim),
         {:ok, receipt} <- paid_receipt(claim),
         {:ok, verification} <- receipt_verification(receipt) do
      issue = Repo.preload(Repo.get!(Issue, spec.issue_id), :repository)

      {:ok,
       %{
         "contract" => "openagents.settlement.payment-receipt.v1",
         "issue" => issue_reference(issue),
         "buyer_kind" => reference_kind(spec.buyer_ref),
         "amount_sats" => receipt.amount_sats,
         "fee_sats" => receipt.fee_sats,
         "unit" => "sat",
         "state" => claim.state,
         "spec_fingerprint" => spec.spec_fingerprint,
         "acceptance_criteria" => spec.acceptance_criteria,
         "commit_sha" => verification.commit_sha,
         "work_job_ref" => claim.work_job_ref,
         "verifier_kind" => reference_kind(verification.verifier_ref),
         "verification_evidence_digest" => verification.evidence_digest,
         "destination_kind" => claim.destination_kind,
         "destination" => claim.destination,
         "payment_hash" => receipt.payment_hash,
         "preimage_digest" => receipt.preimage_digest,
         "paid_at" => DateTime.to_iso8601(receipt.paid_at),
         "receipt_digest" => receipt.receipt_digest
       }}
    end
  end

  @doc "The claim of a specification, live or terminal, or nil."
  @spec claim_for(BountySpec.t()) :: Claim.t() | nil
  def claim_for(%BountySpec{} = spec) do
    Claim
    |> where(bounty_spec_id: ^spec.id)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp dispatch(_claim, _spec, _policy, %PaymentIntent{state: "paid"} = intent),
    do: settled_intent(intent)

  defp dispatch(_claim, _spec, _policy, %PaymentIntent{state: "refunded"}),
    do: {:error, :payment_refunded}

  defp dispatch(claim, spec, policy, %PaymentIntent{attempts: 0} = intent) do
    with :ok <- require_attempts_remaining(policy, intent),
         :ok <- require_daily_budget(policy, intent) do
      pay(claim, spec, intent)
    end
  end

  defp dispatch(claim, spec, policy, %PaymentIntent{} = intent) do
    with :ok <- require_attempts_remaining(policy, intent),
         :ok <- require_daily_budget(policy, intent) do
      case PaymentGateway.lookup(intent.idempotency_key) do
        {:ok, settled} -> record_settlement(intent, settled)
        {:pending, reason_code} -> hold(intent, reason_code)
        _unsettled -> pay(claim, spec, intent)
      end
    end
  end

  defp pay(claim, spec, intent) do
    request = %{
      idempotency_key: intent.idempotency_key,
      amount_sats: intent.amount_sats,
      destination_kind: claim.destination_kind,
      destination: claim.destination,
      memo: "bounty #{spec.spec_fingerprint} commit #{intent.commit_sha}"
    }

    case PaymentGateway.pay(request) do
      {:ok, settled} -> record_settlement(intent, settled)
      {:pending, reason_code} -> hold(intent, reason_code)
      {:error, reason_code} -> record_failure(intent, reason_code)
      {:unknown, _nothing} -> record_failure(intent, "payment_gateway_unknown")
    end
  end

  defp reconcile_open(%PaymentIntent{} = intent) do
    case PaymentGateway.lookup(intent.idempotency_key) do
      {:ok, settled} -> record_settlement(intent, settled)
      {:pending, reason_code} -> hold(intent, reason_code)
      _unsettled -> {:error, :payment_unsettled}
    end
  end

  defp record_settlement(%PaymentIntent{} = intent, settled) do
    with {:ok, evidence} <- validate_settled(intent, settled) do
      Repo.transaction(fn ->
        digest =
          Canonical.digest!(%{
            "intent_digest" => intent.intent_digest,
            "amount_sats" => intent.amount_sats,
            "fee_sats" => evidence.fee_sats,
            "payment_hash" => evidence.payment_hash,
            "preimage_digest" => evidence.preimage_digest,
            "paid_at" => DateTime.to_iso8601(evidence.paid_at)
          })

        receipt =
          %PaymentReceipt{}
          |> PaymentReceipt.changeset(%{
            payment_intent_id: intent.id,
            claim_id: intent.claim_id,
            amount_sats: intent.amount_sats,
            fee_sats: evidence.fee_sats,
            payment_hash: evidence.payment_hash,
            preimage_digest: evidence.preimage_digest,
            gateway_ref: evidence.gateway_ref,
            paid_at: evidence.paid_at,
            receipt_digest: digest
          })
          |> Repo.insert()
          |> or_rollback()

        paid_intent =
          intent
          |> PaymentIntent.result_changeset(%{
            state: "paid",
            attempts: intent.attempts + 1,
            failure_reason_code: nil
          })
          |> Repo.update()
          |> or_rollback()

        claim =
          Claim
          |> Repo.get!(intent.claim_id)
          |> Claim.state_changeset("paid")
          |> Repo.update()
          |> or_rollback()

        %{claim: claim, intent: paid_intent, receipt: receipt}
      end)
      |> transaction_result()
    end
  end

  defp record_failure(%PaymentIntent{} = intent, reason_code) do
    result =
      intent
      |> PaymentIntent.result_changeset(%{
        state: "failed",
        attempts: intent.attempts + 1,
        failure_reason_code: reason_code
      })
      |> Repo.update()

    case result do
      {:ok, _failed} -> {:error, {:payment_failed, reason_code}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp hold(%PaymentIntent{} = intent, reason_code) do
    result =
      intent
      |> PaymentIntent.result_changeset(%{
        state: "pending",
        attempts: intent.attempts + 1,
        failure_reason_code: reason_code
      })
      |> Repo.update()

    case result do
      {:ok, pending} -> {:pending, pending}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp settled_result(%PaymentIntent{} = intent, %PaymentReceipt{} = receipt) do
    {:ok, %{claim: Repo.get!(Claim, intent.claim_id), intent: intent, receipt: receipt}}
  end

  defp payment_intent(claim, spec, verification, operator) do
    case Repo.get_by(PaymentIntent, idempotency_key: operator.idempotency_key) do
      %PaymentIntent{} = intent ->
        require_matching_intent(intent, claim, spec, verification, operator)

      nil ->
        insert_intent(claim, spec, verification, operator)
    end
  end

  defp insert_intent(claim, spec, verification, operator) do
    digest =
      Canonical.digest!(%{
        "claim_digest" => claim.claim_digest,
        "spec_fingerprint" => spec.spec_fingerprint,
        "commit_sha" => verification.commit_sha,
        "amount_sats" => spec.amount_sats,
        "idempotency_key" => operator.idempotency_key
      })

    result =
      %PaymentIntent{}
      |> PaymentIntent.changeset(%{
        claim_id: claim.id,
        verification_id: verification.id,
        idempotency_key: operator.idempotency_key,
        amount_sats: spec.amount_sats,
        commit_sha: verification.commit_sha,
        destination_digest: claim.destination_digest,
        spec_fingerprint: spec.spec_fingerprint,
        state: "pending",
        attempts: 0,
        intent_digest: digest,
        actor_id: operator.actor_id,
        auth_method: operator.auth_method,
        approval_receipt_ref: operator.approval_receipt_ref
      })
      |> Repo.insert()

    case result do
      {:ok, intent} ->
        {:ok, intent}

      {:error, changeset} ->
        case Repo.get_by(PaymentIntent, idempotency_key: operator.idempotency_key) do
          %PaymentIntent{} = intent ->
            require_matching_intent(intent, claim, spec, verification, operator)

          nil ->
            {:error, changeset}
        end
    end
  end

  defp require_matching_intent(intent, claim, spec, verification, operator) do
    matches? =
      intent.claim_id == claim.id and intent.spec_fingerprint == spec.spec_fingerprint and
        intent.commit_sha == verification.commit_sha and intent.amount_sats == spec.amount_sats and
        intent.approval_receipt_ref == operator.approval_receipt_ref

    if matches?, do: {:ok, intent}, else: {:error, :idempotency_key_conflict}
  end

  defp require_attempts_remaining(policy, intent) do
    max_attempts = Map.get(policy.rules, "max_attempts", 1)

    if intent.attempts < max_attempts,
      do: :ok,
      else: {:error, :payment_attempts_exhausted}
  end

  defp require_daily_budget(policy, intent) do
    budget = Map.get(policy.rules, "daily_budget_sats", 0)
    window = DateTime.add(DateTime.utc_now(), -86_400, :second)

    paid =
      PaymentIntent
      |> where([intent], intent.state == "paid" and intent.updated_at >= ^window)
      |> select([intent], sum(intent.amount_sats))
      |> Repo.one()
      |> Kernel.||(0)

    if paid + intent.amount_sats <= budget,
      do: :ok,
      else: {:error, :daily_budget_exhausted}
  end

  defp require_payment_authority(policy, spec) do
    max_payment = Map.get(policy.rules, "max_payment_sats", 0)

    if spec.amount_sats <= max_payment,
      do: :ok,
      else: {:error, :amount_exceeds_treasury_authority}
  end

  defp accepted_verification(claim, commit_sha, spec) do
    verification = Repo.get_by(Verification, claim_id: claim.id, commit_sha: commit_sha)

    cond do
      is_nil(verification) and Repo.exists?(where(Verification, claim_id: ^claim.id)) ->
        {:error, :stale_commit}

      is_nil(verification) ->
        {:error, :verification_missing}

      verification.outcome != "accepted" ->
        {:error, :verification_rejected}

      verification.spec_fingerprint != spec.spec_fingerprint ->
        {:error, :spec_fingerprint_mismatch}

      true ->
        {:ok, verification}
    end
  end

  defp adjust(claim, operator, kind, reason_code, claim_state) do
    with {:ok, claim} <- reload_claim(claim),
         :ok <- validate_operator(operator),
         :ok <- validate_reason_code(reason_code) do
      digest =
        Canonical.digest!(%{
          "claim_digest" => claim.claim_digest,
          "kind" => kind,
          "reason_code" => reason_code,
          "approval_receipt_ref" => operator.approval_receipt_ref
        })

      Repo.transaction(fn ->
        adjustment =
          %Adjustment{}
          |> Adjustment.changeset(%{
            claim_id: claim.id,
            kind: kind,
            reason_code: reason_code,
            actor_id: operator.actor_id,
            auth_method: operator.auth_method,
            approval_receipt_ref: operator.approval_receipt_ref,
            adjustment_digest: digest
          })
          |> Repo.insert()
          |> or_rollback()

        claim
        |> Claim.state_changeset(claim_state)
        |> Repo.update()
        |> or_rollback()

        adjustment
      end)
      |> transaction_result()
    end
  end

  defp projection(issue, spec, level) do
    claim = claim_for(spec)
    receipt = claim && paid_receipt_or_nil(claim)

    pulse = %{
      "contract" => "openagents.settlement.public.v1",
      "issue_number" => issue.number,
      "unit" => "sat",
      "amount_sats" => spec.amount_sats,
      "state" => public_state(claim),
      "buyer_kind" => reference_kind(spec.buyer_ref),
      "claimant_kind" => claim && reference_kind(claim.claimant_ref),
      "acceptance_criteria_count" => length(spec.acceptance_criteria),
      "paid" => not is_nil(receipt)
    }

    if level == :l1, do: pulse, else: Map.merge(pulse, ledger(spec, claim, receipt))
  end

  defp ledger(spec, claim, receipt) do
    verification = claim && accepted_verification_or_nil(claim)

    %{
      "spec_fingerprint" => spec.spec_fingerprint,
      "acceptance_criteria" => spec.acceptance_criteria,
      "expires_at" => DateTime.to_iso8601(spec.expires_at),
      "commit_sha" => verification && verification.commit_sha,
      "verifier_kind" => verification && reference_kind(verification.verifier_ref),
      "verification_evidence_digest" => verification && verification.evidence_digest,
      "payment_hash" => receipt && receipt.payment_hash,
      "fee_sats" => receipt && receipt.fee_sats,
      "paid_at" => receipt && DateTime.to_iso8601(receipt.paid_at),
      "receipt_digest" => receipt && receipt.receipt_digest
    }
  end

  defp public_state(nil), do: "priced"
  defp public_state(%Claim{state: state}), do: state

  defp accepted_verification_or_nil(claim) do
    Verification
    |> where([verification], verification.claim_id == ^claim.id)
    |> where([verification], verification.outcome == "accepted")
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp paid_receipt_or_nil(claim) do
    PaymentReceipt
    |> where(claim_id: ^claim.id)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp paid_receipt(claim) do
    case paid_receipt_or_nil(claim) do
      %PaymentReceipt{} = receipt -> {:ok, receipt}
      nil -> {:error, :payment_receipt_missing}
    end
  end

  defp receipt_verification(%PaymentReceipt{} = receipt) do
    intent = Repo.get!(PaymentIntent, receipt.payment_intent_id)

    case Repo.get(Verification, intent.verification_id) do
      %Verification{} = verification -> {:ok, verification}
      nil -> {:error, :verification_missing}
    end
  end

  defp receipt_for(%PaymentIntent{} = intent),
    do: Repo.get_by(PaymentReceipt, payment_intent_id: intent.id)

  defp issue_reference(%Issue{} = issue) do
    %{
      "owner" => issue.repository && issue.repository.owner,
      "repository" => issue.repository && issue.repository.name,
      "number" => issue.number
    }
  end

  defp reference_kind(reference) when is_binary(reference) do
    case String.split(reference, ":", parts: 2) do
      [kind, _identifier] -> kind
      [_identifier] -> "unattributed"
    end
  end

  defp reference_kind(_reference), do: "unattributed"

  defp next_revision(issue) do
    revision =
      BountySpec
      |> where(issue_id: ^issue.id)
      |> select([spec], max(spec.revision))
      |> Repo.one()

    (revision || 0) + 1
  end

  defp claim_spec(%Claim{} = claim) do
    case Repo.get(BountySpec, claim.bounty_spec_id) do
      %BountySpec{} = spec -> {:ok, spec}
      nil -> {:error, :bounty_spec_missing}
    end
  end

  defp reload_claim(%Claim{id: id}) do
    case Repo.get(Claim, id) do
      %Claim{} = claim -> {:ok, claim}
      nil -> {:error, :claim_missing}
    end
  end

  defp require_current_spec(%BountySpec{} = spec) do
    latest =
      BountySpec
      |> where(issue_id: ^spec.issue_id)
      |> select([candidate], max(candidate.revision))
      |> Repo.one()

    if latest == spec.revision, do: :ok, else: {:error, :spec_superseded}
  end

  defp require_pinned_fingerprint(%Claim{} = claim, %BountySpec{} = spec) do
    if claim.spec_fingerprint == spec.spec_fingerprint,
      do: :ok,
      else: {:error, :spec_fingerprint_mismatch}
  end

  defp require_unexpired_spec(%BountySpec{} = spec) do
    if DateTime.compare(spec.expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :bounty_expired}
  end

  defp require_unexpired_claim(%Claim{} = claim) do
    if DateTime.compare(claim.expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :claim_expired}
  end

  defp require_settleable_claim(%Claim{state: state}) when state in ~w(claimed verified),
    do: :ok

  defp require_settleable_claim(%Claim{state: state}),
    do: {:error, {:claim_not_settleable, state}}

  defp require_paid_claim(%Claim{state: "paid"}), do: :ok
  defp require_paid_claim(%Claim{state: state}), do: {:error, {:claim_not_paid, state}}

  defp require_claimant(%Claim{claimant_ref: claimant_ref}, claimant_ref), do: :ok
  defp require_claimant(_claim, _claimant_ref), do: {:error, :not_the_claimant}

  defp validate_operator(operator) when is_map(operator) do
    with :ok <- require_text(operator, :actor_id, 256),
         :ok <- require_text(operator, :auth_method, 128),
         :ok <- require_text(operator, :approval_receipt_ref, 256) do
      :ok
    end
  end

  defp validate_operator(_operator), do: {:error, :operator_invalid}

  defp validate_settlement_request(request) when is_map(request) do
    with :ok <- validate_approval(request),
         :ok <- validate_operator(request),
         :ok <- require_text(request, :idempotency_key, 256),
         {:ok, commit_sha} <- validate_commit_sha(request) do
      {:ok,
       %{
         actor_id: request.actor_id,
         auth_method: request.auth_method,
         approval_receipt_ref: request.approval_receipt_ref,
         idempotency_key: request.idempotency_key,
         commit_sha: commit_sha
       }}
    end
  end

  defp validate_settlement_request(_request), do: {:error, :settlement_request_invalid}

  defp validate_approval(request) do
    case Map.get(request, :approval_receipt_ref) do
      value when is_binary(value) and value != "" -> :ok
      _missing -> {:error, :approval_missing}
    end
  end

  defp validate_commit_sha(request) do
    case Map.get(request, :commit_sha) do
      value when is_binary(value) ->
        if Regex.match?(~r/\A[0-9a-f]{40}\z/, value),
          do: {:ok, value},
          else: {:error, :commit_sha_invalid}

      _missing ->
        {:error, :commit_sha_invalid}
    end
  end

  defp validate_rules(rules) do
    max_payment = Map.get(rules, "max_payment_sats")
    daily_budget = Map.get(rules, "daily_budget_sats")
    max_attempts = Map.get(rules, "max_attempts")
    destinations = Map.get(rules, "destination_kinds")

    cond do
      not (is_integer(max_payment) and max_payment > 0) -> {:error, :max_payment_invalid}
      not (is_integer(daily_budget) and daily_budget >= max_payment) -> {:error, :budget_invalid}
      not (is_integer(max_attempts) and max_attempts > 0) -> {:error, :max_attempts_invalid}
      not (is_list(destinations) and destinations != []) -> {:error, :destination_kinds_invalid}
      Map.get(rules, "requires_accepted_verification") != true -> {:error, :verification_optional}
      Map.get(rules, "requires_approval_receipt") != true -> {:error, :approval_optional}
      true -> :ok
    end
  end

  defp validate_price(policy, attributes) when is_map(attributes) do
    with {:ok, amount_sats} <- validate_amount(policy, attributes),
         {:ok, criteria} <- validate_criteria(attributes),
         {:ok, verification_policy} <- validate_verification_policy(attributes),
         {:ok, destination_kind} <- validate_destination_kind(policy, attributes),
         {:ok, expires_at} <- validate_expiry(attributes),
         :ok <- require_text(attributes, :buyer_ref, 256) do
      {:ok,
       %{
         buyer_ref: attributes.buyer_ref,
         amount_sats: amount_sats,
         acceptance_criteria: criteria,
         verification_policy: verification_policy,
         destination_kind: destination_kind,
         expires_at: expires_at
       }}
    end
  end

  defp validate_price(_policy, _attributes), do: {:error, :bounty_price_invalid}

  defp validate_amount(policy, attributes) do
    amount = Map.get(attributes, :amount_sats)
    max_payment = Map.get(policy.rules, "max_payment_sats", 0)

    cond do
      not is_integer(amount) or amount <= 0 -> {:error, :amount_invalid}
      amount > max_payment -> {:error, :amount_exceeds_treasury_authority}
      true -> {:ok, amount}
    end
  end

  defp validate_criteria(attributes) do
    case Map.get(attributes, :acceptance_criteria) do
      [_first | _rest] = criteria ->
        if Enum.all?(criteria, &(is_binary(&1) and &1 != "")),
          do: {:ok, criteria},
          else: {:error, :acceptance_criteria_invalid}

      _missing ->
        {:error, :acceptance_criteria_invalid}
    end
  end

  defp validate_verification_policy(attributes) do
    case Map.get(attributes, :verification_policy) do
      policy when is_map(policy) and map_size(policy) > 0 -> {:ok, policy}
      _missing -> {:error, :verification_policy_invalid}
    end
  end

  defp validate_destination_kind(policy, attributes) do
    kinds = Map.get(policy.rules, "destination_kinds", [])
    kind = Map.get(attributes, :destination_kind)

    if is_binary(kind) and kind in kinds,
      do: {:ok, kind},
      else: {:error, :destination_kind_not_admitted}
  end

  defp validate_expiry(attributes) do
    case Map.get(attributes, :expires_at) do
      %DateTime{} = expires_at ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
          do: {:ok, expires_at},
          else: {:error, :expiry_in_the_past}

      _missing ->
        {:error, :expiry_invalid}
    end
  end

  defp validate_destination(policy, spec, claimant) when is_map(claimant) do
    kinds = Map.get(policy.rules, "destination_kinds", [])
    kind = Map.get(claimant, :destination_kind)
    value = Map.get(claimant, :destination)

    cond do
      not (is_binary(kind) and kind in kinds) ->
        {:error, :destination_kind_not_admitted}

      kind != spec.destination_kind ->
        {:error, :destination_kind_not_admitted}

      not (is_binary(value) and byte_size(value) >= 16) ->
        {:error, :destination_invalid}

      true ->
        {:ok, %{kind: kind, value: value, digest: Canonical.sha256(value)}}
    end
  end

  defp validate_destination(_policy, _spec, _claimant), do: {:error, :destination_invalid}

  defp validate_claimant(claimant) do
    with :ok <- require_text(claimant, :claimant_ref, 256),
         :ok <- require_text(claimant, :work_job_ref, 256) do
      {:ok, %{claimant_ref: claimant.claimant_ref, work_job_ref: claimant.work_job_ref}}
    end
  end

  defp validate_verification(claim, spec, attributes) when is_map(attributes) do
    expected_policy_digest = Canonical.digest!(spec.verification_policy)

    with {:ok, commit_sha} <- validate_commit_sha(attributes),
         :ok <- require_text(attributes, :verifier_ref, 256),
         :ok <- require_text(attributes, :auth_method, 128),
         :ok <- require_text(attributes, :decision_receipt_ref, 256),
         :ok <- validate_reason_code(Map.get(attributes, :reason_code)),
         {:ok, outcome} <- validate_outcome(attributes),
         {:ok, evidence_digest} <- validate_evidence_digest(attributes),
         :ok <- require_verifier_policy(attributes, expected_policy_digest),
         :ok <- require_claim_work_job(claim, attributes) do
      {:ok,
       %{
         commit_sha: commit_sha,
         verifier_ref: attributes.verifier_ref,
         verifier_policy_digest: expected_policy_digest,
         evidence_digest: evidence_digest,
         outcome: outcome,
         reason_code: attributes.reason_code,
         auth_method: attributes.auth_method,
         decision_receipt_ref: attributes.decision_receipt_ref
       }}
    end
  end

  defp validate_verification(_claim, _spec, _attributes), do: {:error, :verification_invalid}

  defp validate_outcome(attributes) do
    case Map.get(attributes, :outcome) do
      outcome when outcome in ~w(accepted rejected) -> {:ok, outcome}
      _invalid -> {:error, :verification_outcome_invalid}
    end
  end

  defp validate_evidence_digest(attributes) do
    case Map.get(attributes, :evidence_digest) do
      digest when is_binary(digest) ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
          do: {:ok, digest},
          else: {:error, :evidence_digest_invalid}

      _missing ->
        {:error, :evidence_digest_invalid}
    end
  end

  defp require_verifier_policy(attributes, expected) do
    case Map.get(attributes, :verifier_policy_digest) do
      nil -> :ok
      ^expected -> :ok
      _other -> {:error, :verifier_policy_mismatch}
    end
  end

  defp require_claim_work_job(claim, attributes) do
    case Map.get(attributes, :work_job_ref) do
      nil -> :ok
      work_job_ref when work_job_ref == claim.work_job_ref -> :ok
      _other -> {:error, :work_job_mismatch}
    end
  end

  defp validate_settled(_intent, settled) when is_map(settled) do
    with {:ok, payment_hash} <- digest_field(settled, :payment_hash, :payment_hash_invalid),
         {:ok, preimage_digest} <- digest_field(settled, :preimage_digest, :preimage_invalid),
         {:ok, paid_at} <- paid_at(settled),
         {:ok, fee_sats} <- fee_sats(settled),
         :ok <- require_text(settled, :gateway_ref, 256) do
      {:ok,
       %{
         payment_hash: payment_hash,
         preimage_digest: preimage_digest,
         paid_at: paid_at,
         fee_sats: fee_sats,
         gateway_ref: settled.gateway_ref
       }}
    end
  end

  defp validate_settled(_intent, _settled), do: {:error, :payment_evidence_invalid}

  defp digest_field(settled, key, error) do
    case Map.get(settled, key) do
      value when is_binary(value) ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: {:ok, value}, else: {:error, error}

      _missing ->
        {:error, error}
    end
  end

  defp paid_at(settled) do
    case Map.get(settled, :paid_at) do
      %DateTime{} = paid_at -> {:ok, paid_at}
      _missing -> {:error, :paid_at_invalid}
    end
  end

  defp fee_sats(settled) do
    case Map.get(settled, :fee_sats) do
      fee when is_integer(fee) and fee >= 0 -> {:ok, fee}
      _invalid -> {:error, :fee_sats_invalid}
    end
  end

  defp validate_reason_code(reason_code) do
    if is_binary(reason_code) and reason_code != "" and byte_size(reason_code) <= 128,
      do: :ok,
      else: {:error, :reason_code_invalid}
  end

  defp require_text(source, key, max_bytes) do
    case Map.get(source, key) do
      value when is_binary(value) ->
        if value != "" and byte_size(value) <= max_bytes,
          do: :ok,
          else: {:error, {:invalid_field, key}}

      _missing ->
        {:error, {:invalid_field, key}}
    end
  end

  defp or_rollback({:ok, record}), do: record
  defp or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
