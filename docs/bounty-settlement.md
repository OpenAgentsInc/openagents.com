# Bounty settlement

`OpenAgents.Settlement` prices a forge issue in sats, admits one claim, grades
the delivery at an exact commit, and pays the claimant from the treasury against
an inspectable receipt chain. The contract is `SETTLEMENT-001` in
[`INVARIANTS.md`](../INVARIANTS.md), proven by
[`test/openagents/settlement_test.exs`](../test/openagents/settlement_test.exs).

The settlement authority is separate from attribution accounting. Compensation
accounting still holds `payout_authority: false` (`COMPENSATION-001`); nothing in
this loop grants it a payment operation.

## The loop

1. **Admit the treasury policy.** `admit_treasury_policy/2` records the maximum
   payment, the daily budget, the attempt bound, the admitted self-custodial
   destination kinds, and the refund, expiry, retry, and dispute behavior, with
   the operator identity, the authentication method, and the approval reference
   behind it. The policy digest covers its exact rules.
2. **Price the issue.** `price_bounty/3` records the named buyer, the sats
   amount, the acceptance criteria, the verification policy, the destination
   kind, and the expiry, then fingerprints all of them together with the policy
   digest and the revision. Repricing appends a revision with a new fingerprint.
3. **Claim it.** `claim_bounty/2` pins the fingerprint and the claimant's own
   destination, and stores the destination digest next to it. One claim holds a
   specification at a time; an expired or rejected claim releases it.
4. **Verify the delivery.** `verify_claim/2` records a qualification receipt for
   one claim at one commit, under the specification's own verifier policy digest
   and the claim's own work job. An accepted verification moves the claim to
   `verified`; a rejected one moves it to `rejected`.
5. **Settle.** `settle/2` needs the exact commit, an approval reference, and an
   idempotency key. It refuses a superseded specification, a moved fingerprint, a
   commit without its own verification, an expired claim, a dispute, an amount
   above the treasury authority, an exhausted daily budget, and an exhausted
   attempt bound. It then dispatches one payment through the configured gateway
   and records the exact receipt.
6. **Export the evidence.** `export_payment_receipt/2` gives the claimant the
   amount, the fee, the payment hash, the preimage digest, the commit, the
   fingerprint, and their own destination. `public_projection/1` publishes only
   what the repository's disclosure level admits.

## Custody

The domain holds no keys, no node, and no wallet. `PaymentGateway` is the whole
boundary: it takes an authorized, idempotency-keyed request and answers `{:ok,
settled}`, `{:pending, reason_code}`, or `{:error, reason_code}`. Configure the
production gateway with `:settlement_payment_gateway`. Without that
configuration, `PaymentGateway.Unconfigured` refuses every payment, so an
unprepared environment fails closed instead of appearing to pay.

The claimant is paid at a destination they control, so nobody needs a hosted
OpenAgents wallet to collect a bounty.

Forum tipping keeps its own narrower boundary,
`OpenAgents.Forum.Tips.PaymentService`, because a tip is a one-shot transfer
between two people. A treasury payment also has to survive a lost
acknowledgement, so the settlement gateway additionally answers `lookup/1` for
the terminal state of an idempotency key.

## What stops a second payment

One idempotency key names one payment intent for the life of the settlement:

- A duplicate request returns the first receipt and never calls the gateway
  again.
- A failed attempt retries under the same key until the policy attempt bound.
- A lost acknowledgement stays `pending`; `reconcile/1` asks the gateway for the
  key's terminal state and turns a settled key into its receipt.
- A partial unique index allows one `paid` intent per claim, one receipt per
  intent, and one row per payment hash.
- Reusing a key for a different claim fails with `:idempotency_key_conflict`.

## Expiry, dispute, and refund

`expire_claim/3`, `open_dispute/3`, and `refund/3` append an adjustment carrying
the operator identity, the authentication method, the approval reference, and a
reason code. An expiry releases the specification for another claimant. A dispute
freezes settlement. A refund applies only to a paid claim and never rewrites the
payment receipt.

## What stays private

Public projections carry the amount, the status, reference kinds, the acceptance
criteria count, and — at the ledger level — the fingerprint, the commit, the
payment hash, and the receipt digest. They never carry a destination, a claimant
or buyer reference, a work job reference, an operator identity, an approval
reference, a gateway reference, or a preimage digest.
