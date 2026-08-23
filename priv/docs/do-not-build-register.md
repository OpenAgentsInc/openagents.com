# Do-not-build register

The do-not-build register records product and architecture directions that
OpenAgents retired, deferred, rejected, or superseded. It keeps agents and
maintainers from repeatedly proposing work whose replacement already exists.

The public, machine-readable contract is
[`/api/contracts/do-not-build-v1.json`](/api/contracts/do-not-build-v1.json).
It is the authority for the current decisions, exact matching phrases, and
decision history.

## What each entry records

Every entry has:

- A stable `DNB-###` ID.
- The scope covered by the decision.
- A current decision state: `retired`, `deferred`, `rejected`, or
  `superseded`.
- The decision date and evidence.
- The principle the proposal violated.
- The supported replacement path.
- An owner and a concrete reconsideration trigger.
- An append-only decision history.

## How screening works

Screening uses the explicit multi-word phrases in each entry. It does not
expand a product name into a broad keyword rule. A proposal that mentions Bun,
Spark, Copilot, Rust, or Claude Code for an unrelated reason is not blocked.

FastFollow integrations can call
`OpenAgents.DoNotBuildRegister.screen_fast_follow/2`. A match returns
`{:suppressed, entry}` and records `fast_follow_proposal_suppressed` with the
entry ID, decision state, and a content fingerprint. Proposal text is not sent
to analytics.

## Reconsider a decision

Do not reopen matching work from a new assertion alone.

1. Add evidence that did not exist when the current decision was made.
2. Write an explicit decision record.
3. Update the register by appending a complete history item and making it the
   current decision.
4. Review the change before starting implementation.

Supplying new evidence and a decision-record reference to the FastFollow
screen moves the result to `{:review_required, entry}`. It does not silently
override the committed register.

## Initial decisions

The first register covers:

- Hosted Spark custody.
- NIP-90 data-vending-machine markets without demonstrated demand.
- Bun in the production trust path.
- GetAfter as a second forge.
- Presence-based mining and pay-for-online rewards.
- Copilot as an executor target.
- A monolithic all-in-one business operating system.
- A standalone Rust Sarah service.
- Claude Code or another rival-owned runtime as a hard dependency.
