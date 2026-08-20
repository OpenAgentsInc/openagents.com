# Gate 8 asynchronous-runtime evidence

Date: 2026-08-20

Implementation SHA: `6a812a22e9942f88b2593dc0d7b18fba13cabc53`

Gate 8 passed locally on the exact implementation commit. The evidence set is
content-free and contains no credentials, hostnames, database URLs, private
repository content, conversation content, or staging data.

## Evidence

- `baseline-receipt.json` is the immutable result copied from the owned
  exact-SHA gate receipt. Precommit, merged coverage, all nine distributed
  tests, browser tests, and the packaged production release startup passed
  without retries.
- `migration-rehearsal.json` records a populated forward, reverse, and second
  forward migration rehearsal. It verifies the legacy delegation backfill,
  immutable execution identity, the permitted fenced session checkpoint, and
  data preservation across rollback.
- The direct recovery tests kill or interrupt the real text-turn, semantic, and
  delegated-work processes. They start the recovery workers under supervision
  and assert the durable terminal or reclaimed state. The voice test starts the
  real startup recovery worker over an admitted generation.

The release startup and migration rehearsal used disposable PostgreSQL
databases. The migration-rehearsal database was dropped after verification. No
staging or production deployment occurred.
