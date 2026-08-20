# Gate 6 local evidence

Date: 2026-08-20

Candidate: `04b2faf47080aa7b5bce43b4319fa0276eb3da05`

Status: Local application controls passed; staging operational proof pending

The exact committed candidate passed the owned baseline without retries:

- `mix precommit`: passed
- default Elixir tests: 1,267 passed; 9 cluster-tagged tests excluded
- browser JavaScript tests: 17 passed
- distributed Elixir tests: 9 passed
- merged line coverage: 83.29%, above the enforced 83% floor
- packaged production release build, readiness, migrations, startup, bounded
  health response, and graceful termination: passed against disposable
  PostgreSQL
- Gate 6 migration rollback and forward rehearsal: passed

The retained [baseline receipt](baseline-receipt.json) is content-free and tied
to the implementation SHA. The [Gate 6 receipt](gate-6-local-receipt.json)
records which controls this local evidence covers and which staging operations
remain blocking.

No staging or production deployment occurred. This evidence does not claim the
required staging credential rotation, load-balancer query suppression, or
full-window staging log scan. Those checks remain mandatory before Gate 6 can
close and before the Gate 15 candidate can be admitted.
