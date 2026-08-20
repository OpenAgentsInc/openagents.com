# Gate 10 transactional fleet deployment evidence

Date: 2026-08-20

Implementation SHA: `6999983b4487c0fe0acdb73c10b34327cdb0de5a`

Gate 10 passed locally on the exact implementation commit. This evidence set
is content-free and contains no credentials, database URLs, hostnames, private
repository content, conversation content, or staging data.

## Evidence

- `baseline-receipt.json` is the immutable result copied from the owned
  exact-SHA gate receipt. Precommit, merged coverage, all 14 distributed
  tests, 17 browser tests, and packaged production-release startup passed
  without retries.
- `migration-rehearsal.json` records a populated forward, reverse, and second
  forward rehearsal of the deployment-receipt migration. It verifies legacy
  receipt backfill, immutable receipt enforcement, data preservation across
  rollback, and repeatable forward migration.
- `transactional-fleet-proof.json` identifies the real three-node scenarios
  included in the distributed lane: successful commit, exact fleet rollback,
  unverified rollback refusal, participant timeout, and membership loss.

The release startup and migration rehearsal used newly provisioned disposable
PostgreSQL roles and databases. Cleanup checks confirmed that both databases
and both roles were removed. No staging or production deployment occurred.
