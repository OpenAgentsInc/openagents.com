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

## Related records

- Issue-to-job and receipt linkage: `docs/2026-08-21-issues-projects-work-system-assessment.md`, Track E.
- Source episodes: `docs/episode-triage.md`, episodes 237, 251, 252, 259, and 264.
- Invariant: `INVARIANTS.md`, OUTCOME-001.
