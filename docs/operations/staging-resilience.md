# Run controlled failures and the 48-hour staging soak

Date: 2026-08-20

Status: Harness implemented and locally proven; live Gate 15 execution pending

Use this runbook after one exact candidate has passed Gate 14. It records all
controlled-failure attempts, requires 48 measured hours without a redeploy,
enforces scheduled canary and metric minimums, and refuses completion when any
unexplained harm remains.

This is a staging-only destructive test plan. Never run it against production,
a shared database, a shared connection budget, a shared fleet, or credentials
that authorize another environment.

## Prove the safety fence

Before injecting a failure, confirm all of these conditions:

- The Gate 14 report is `regression_passed` for the selected candidate.
- Staging has its own project, VPC, private database instance, web lane,
  distributed fleet, deployer, identities, buckets, registry, and credentials.
- Every cloud target contains the reviewed staging project number. No command
  uses an implicit CLI project.
- Database backups, snapshots, rollback artifacts, and last-known-good release
  identities are current and restore-tested.
- A manifest-scoped disposable run owns every test account, repository,
  recording, and product machine.
- The operator has a stop condition, a recovery command, and an observation
  window for the single failure being injected.
- No unrelated staging user or test is active.

Keep production identifiers only as comparison fences. Do not run two failures
at once. Restore the healthy baseline and run a bounded smoke between cases.

## Prove the local harness

Run the network-free check:

```sh
ops/staging/resilience.sh check
```

Expected result:

```text
Staging resilience harness dry run passed (11 failures; 48-hour soak; no network requests sent).
```

The check validates the versioned matrix, report generator, evidence scanner,
attempt recorder, final validator, exact 48-hour duration, six canary schedules,
and fail-closed finalization.

## Create the resilience report

Use the same candidate directory and passed Gate 14 report:

```sh
candidate_sha=$(git rev-parse HEAD)
candidate_dir=".git/openagents/staging-candidates/$candidate_sha"
gate14_run="gate14-20260820-0001"
gate14_report=".git/openagents/staging-reports/$candidate_sha/$gate14_run/report.json"
resilience_run="gate15-20260820-0001"

ops/staging/new-resilience-report.sh \
  "$candidate_dir" "$gate14_report" "$resilience_run"
```

The generator verifies the candidate manifest and Gate 14 report, compares the
candidate SHA, and creates a mode-`0600` report at:

```text
.git/openagents/staging-resilience/<candidate-sha>/<run-id>/report.json
```

Validate the draft:

```sh
resilience_report=".git/openagents/staging-resilience/$candidate_sha/$resilience_run/report.json"
ops/staging/validate-resilience-report.sh --draft "$resilience_report"
```

## Record a controlled-failure attempt

Create a content-free receipt with the candidate identity, failure ID, UTC
window, injected condition, stop condition, observed bounded states, recovery
action, recovery time, post-recovery smoke hash, and zero-or-bounded error
counts. Never retain request bodies, product content, credentials, private IPs,
or raw database rows.

Record a pass:

```sh
ops/staging/record-result.sh \
  "$resilience_report" failure-001 passed controlled-failure \
  /path/to/sanitized-recovery-receipt.json
```

Record a failure or block with a short mode-`0600` reason file:

```sh
ops/staging/record-result.sh \
  "$resilience_report" failure-001 failed controlled-failure \
  /path/to/sanitized-recovery-receipt.json /path/to/reason.txt
```

After correction, append a passed retry. The recorder preserves the failed
attempt. All 11 scenarios are part of the architecture and cannot be marked not
applicable.

## Inject one failure at a time

Use `ops/staging/resilience-matrix.json` as the canonical inventory. For every
case, capture baseline identity and health, inject only the named condition,
observe the documented bound, restore service, and run the full public smoke
plus the affected authenticated flow.

### Provider stream failures

Inject a timeout, one malformed provider event, and a closed stream without a
completion event in separate sub-attempts. Prove that the turn becomes an honest
failed or incomplete terminal state, no false completion is persisted, budgets
stop, partial output remains bounded, and a later turn succeeds.

### PostgreSQL restart and exhaustion

Snapshot first. Restart only the isolated staging database, then separately
consume the staging-only connection reserve with a bounded test client. Prove
that writes fail or retry according to their contracts, no committed row is
lost or duplicated, readiness reflects the outage, connections return below
budget, and the last-known-good application remains compatible.

Stop immediately if any production instance, connection, or service account
appears in the target inventory.

### PubSub interruption and LiveView reconnect

Interrupt the staging PubSub path while preserving PostgreSQL. Prove that UI
projections may become stale but durable truth remains correct, reconnect
restores the projection, and no action executes twice.

### Supervised process termination

Terminate one staging process at a time for turn, voice, work, semantic recall,
builder, and deployer paths. Use the supervisor-visible PID, not a broad system
kill. Prove each durable terminal state, restart behavior, idempotency fence,
receipt, and user-visible recovery contract.

### Machine disconnect

Disconnect a disposable machine during a harmless committed step. Prove that
the lease or step cannot execute twice, committed evidence survives, the job
reaches a bounded state, reconnection does not expand authority, and revoke plus
cleanup still work.

### Artifact-store and cache faults

Refuse the staging artifact store, then separately present a corrupt cache
entry. Prove checksum refusal, readiness fencing, bounded retry, no unverified
load, and convergence to the durable candidate after restoration.

### Unreachable node and membership change

Make one staging fleet node unreachable. Prove that a deployment cannot become
live with a partial fleet and that restored nodes converge before readiness.
In a separate attempt, change membership during a deployment and prove that the
transaction uses one reviewed participant set or aborts and rolls every affected
node back.

### Builder sidecar failure

Crash the isolated builder sidecar and inject a stale response with the wrong
request identity. Prove that the request remains bounded, stale output cannot
attach to a new build, no artifact becomes eligible, and a clean retry produces
one immutable manifest.

### Browser and recording failures

Navigate away and destroy the active tab during microphone use. Prove tracks,
audio elements, peer connections, recorder graphs, and server sessions close
within their bounds. Separately fail a recording upload and send a late final
chunk. Prove generation fencing, honest recording state, retention behavior,
and continued typed and live-voice usability.

## Seal the controlled-failure pass

When every scenario has an outcome, a report with failures can be sealed for
review:

```sh
ops/staging/finalize-report.sh --recorded "$resilience_report"
```

Corrective attempts return it to draft. Do not start the soak until all 11 last
attempts pass, the candidate is healthy, and the test data is reconciled.

## Run 48 hours without a redeploy

Record a UTC start time after the final failure-recovery smoke. Keep the web and
distributed staging lanes on the exact candidate for at least 172,800 seconds.
Any application, configuration, image, release, migration, or fleet redeploy
invalidates the soak; set `redeploy_count` honestly and start a new 48-hour run.

Use these minimum schedules:

| Canary or sample | Cadence | Minimum over 48 hours |
| --- | ---: | ---: |
| Status and candidate identity | 5 minutes | 576 passes |
| Resource metrics | 5 minutes | 576 complete samples |
| Typed chat | 30 minutes | 96 passes |
| Memory write/read/forget | 30 minutes | 96 passes |
| Tracker read/write/cleanup | 30 minutes | 96 passes |
| Git clone/fetch/push/cleanup | 30 minutes | 96 passes |
| Fake-media voice lifecycle | 2 hours | 24 passes |

Each canary receipt must bind the candidate SHA, image digest, scheduled and
actual UTC time, bounded outcome, attempt count, and cleanup result. A retry does
not remove the initial failed observation. The final aggregate canary count must
contain only completed attempts, and every completed attempt must pass before
the report can complete.

Each metric sample records bounded values for database connections, queue depth,
mailbox growth, process count, memory, CPU, restart count, artifact cache, Ra
state, and node convergence. Keep exact revision labels and counts; omit log
content, host addresses, database values, and credentials.

Investigate every crash, unexplained retry, stale active row, divergent node,
leaked process, and content-bearing log entry during the soak. A high or critical
known issue must be resolved. A low or medium issue can be accepted only with a
named owner and an explicit non-blocking disposition.

After 48 hours, run the full Gate 14 public and authenticated smoke again without
redeploying. Record the exact end time after that smoke.

## Complete and validate the resilience report

Attach sanitized timeline, metric, canary, and post-soak-smoke receipts under
the resilience report's `evidence/` directory. Populate the soak counts and
booleans described in the
[resilience evidence contract](staging-resilience-report-template.md).

Finalization requires all failure cases passed, at least 48 measured hours,
zero redeploys, stable candidate identity, every canary minimum, at least 576
metric samples, and zero unexplained error, data-loss, authority-expansion,
fleet-divergence, secret-leak, or restart counts:

```sh
ops/staging/finalize-report.sh --final "$resilience_report"
```

The command validates every nested evidence path, checksum, owner-only mode,
and safety scan before replacing the report.

## Attach Gate 15 to the staging report

Copy the completed resilience report and its `evidence/` directory beneath the
Gate 14 report as one self-contained tree, for example:

```text
<gate14-report-directory>/evidence/gate15/
  report.json
  report.sha256
  evidence/
    ...
```

Scan the copied tree and verify every checksum. Add one reference with kind
`resilience-report` to both `failure_injection_timeline` and `soak_receipt` in
the main staging report. The main validator reruns the full resilience
validator and requires its candidate SHA and image digest to match Gate 14.

Then finalize the main report:

```sh
ops/staging/finalize-report.sh --final "$gate14_report"
```

Retain only the sanitized, checksummed tree in staging evidence storage. Gate 15
completion does not authorize production.
