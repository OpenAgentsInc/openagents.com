# Accepted-outcome contract

This document defines when work that an agent claims is complete counts as an
accepted outcome. It is the shared definition of done for contribution and
review, and it is falsifiable: every part of a claim can be checked, and a
claim that cannot be checked is not accepted.

The published contract lives at `priv/api-contracts/accepted-outcome-v1.json`.
`OpenAgents.AcceptedOutcome` evaluates claims against it, and
`test/openagents/accepted_outcome_test.exs` proves the accepted, failed,
incomplete, unauthorized, and private-evidence cases. The issue stays the
canonical work record; the contract only grades claims about it.

## The parts of a claim

An accepted outcome connects five things. Remove any one of them and the
claim is not accepted.

1. **A scoped issue.** The implementation issue states the requested outcome
   in four required sections: problem, scope, acceptance criteria, and
   success metrics. An issue without them cannot anchor an accepted outcome.
2. **A bound attempt.** Each execution attempt records the issue number, the
   repository, the authority it acted under, its budget, and the exact
   revision it produced. An attempt bound to a different issue or repository
   is unauthorized.
3. **Independent verification.** Evidence counts only when the verifier is
   admitted. When policy requires producer-verifier separation, the verifier
   must also be independent of the producer.
4. **A falsifier and a terminal result.** The claim records what observation
   would have proven it wrong and whether the verifier passed or failed, so
   every green result could have been red.
5. **Inspectable evidence.** Each acceptance criterion names the receipt that
   satisfied it, and the issue page can explain which evidence satisfied
   which criterion.

## Typed non-accepted results

A claim that falls short produces a typed result, never silence:

- `incomplete` — the claim is structurally short: a missing issue section, a
  missing attempt field, a missing verifier, falsifier, or terminal result,
  or an acceptance criterion with no evidence.
- `unauthorized` — the attempt is not bound to the issue and repository it
  changed, the verifier is not admitted, or required producer-verifier
  separation does not hold.
- `failed` — the verifier reported failure, or a false-green class is
  recorded against the result.

## False-green classes

Review and receipt data name five failure modes in which a green result does
not prove the outcome:

- `false_green_fixture_assert` — the test asserts on its own fixture rather
  than the behavior.
- `false_green_api_mirror` — the test restates the implementation instead of
  observing an outcome.
- `false_green_mocked_seam` — the mocked boundary is the behavior under test.
- `false_green_coverage_theater` — coverage numbers stand in for assertions.
- `false_green_round_up` — a partial result is reported as complete.

A result that names any of these classes is `failed` even when the verifier
reported green.

## Visibility

Public projections of an evaluation carry only the result state, typed
reasons, criterion names, and receipt references that are public. They never
carry prompts, logs, private repository names, or private receipt references.
A criterion satisfied by private evidence appears publicly as satisfied by
private evidence, without the reference.

## Human-only work

The contract gates only agent-authored claims. Human-only work and
repositories with agents disabled evaluate to `not_applicable` and remain
fully usable; nothing about the issue workflow changes for them.

## Definition of done for agent work

An agent-authored change is done when its claim evaluates to `accepted`:

- The issue is scoped with problem, scope, acceptance criteria, and success
  metrics.
- The attempt binds the issue, repository, authority, budget, and exact
  revision.
- An admitted verifier — independent when policy requires separation —
  recorded a falsifier and passed.
- Every acceptance criterion names its inspectable receipt.
- No false-green class is recorded against the result.

Contribution and review use this same definition. Reviewers grade claims, not
prose: a report that sounds complete but fails a check above is a typed
non-accepted result, and the review states which one.

## Closing an issue from a claim

A claim is stored whether or not it is accepted, so a refusal is on the record
rather than silent. `OpenAgents.Issues.CompletionClaims` writes one
`issue_completion_claims` row per `{issue, attempt, revision}` and grades it
with `OpenAgents.AcceptedOutcome.evaluate/1`.

The caller supplies one thing: which evidence satisfied which acceptance
criterion. It may also name false-green classes against its own result, which
can only make the verdict worse. Everything else is read from records — the
issue's sections from its body, the attempt's five binding fields from
`forge_assignments` and its work job's budget snapshot, the verifier from the
published check result the evidence resolves to, and the falsifier as that
check's own identity reporting `failed`. Producer-verifier separation is always
required here, so an attempt whose requester also published the check is
`unauthorized`.

### What can close, and what can only claim

| Receipt family | Record | Close | Why |
| --- | --- | --- | --- |
| `qualification` | Yes | **Yes** | A verdict about named bytes. Identity is `{repository, name, commit, artifact digest}`, so a green result cannot be replayed onto bytes it never examined, and the publisher is an authorized principal that is not the attempt. |
| `build` | Yes | No | That the tree compiles at that commit. Necessary for anything to work; sufficient for nothing to be done. |
| `deployment` | Yes | No | That an artifact reached an environment. Placement, not behavior. A `fleet` deployment and a named tenant environment are both operational facts. |
| `push` | Yes | No | That the forge received the bytes. It carries no outcome at all; its `result` is null. |

A qualification receipt closes only at the exact revision the attempt reported,
only with the status `succeeded`, and only for the issue that already claims
that commit. An evidence reference to anything else resolves to no receipt, so
the criterion it names is unevidenced and the claim is `incomplete`.

### The rest of the rule

- **Two opt-ins.** `repository_closure_policies.agents_enabled` decides whether
  a claim is graded at all; `verified_closing_enabled` decides whether an
  accepted claim may move the issue. Both default false, and an absent row
  means the same as both false.
- **No contradiction.** If any evidence edge for that issue at that revision
  carries its family's word for failure — a failed or expired build, a
  reverted, failed, cancelled, or superseded deployment, a failed check — the
  verdict is recorded and the close is withheld.
- **Never reopen.** A failing receipt that arrives after an accepted claim
  closed the issue stamps `contradicted_at` on the claim and names the edge.
  The issue stays closed and a person decides.
- **One closer.** `#130`'s trailer path is unchanged and stays attributed to
  the person who wrote the trailer. This path closes only issues that are still
  open. A reader tells them apart by the record: a person's close leaves an
  `issue_closing_references` row with a `closed_by_user_id`; this one leaves an
  `issue_completion_claims` row whose `closed_by_actor` is
  `system:accepted-outcome`, which is never a user id.

## Related records

- Issue-to-job and receipt linkage: `docs/2026-08-21-issues-projects-work-system-assessment.md`, Track E.
- Source episodes: `docs/episode-triage.md`, episodes 237, 251, 252, 259, and 264.
- Invariant: `INVARIANTS.md`, OUTCOME-001.
