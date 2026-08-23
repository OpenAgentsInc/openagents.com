# Run the staging regression and retain safe evidence

Date: 2026-08-20

Status: Harness implemented and locally proven; live Gate 14 execution pending

Use this runbook to test one immutable candidate on the isolated staging
environment and produce one checksummed report. The harness covers every Gate
14 case, preserves failed attempts, refuses incomplete reports, and keeps raw
product content and credentials out of retained evidence.

This runbook never authorizes a production action. Its only network target is
`https://staging.openagents.com`.

## Understand the harness boundary

The harness provides these controls:

- `regression-matrix.json` defines 69 cases in 10 groups.
- `regression.sh check` validates the matrix, report generator, validator,
  evidence scanner, and public-smoke preflight without making a network request.
- `new-report.sh` binds a report to the exact candidate manifest and its image,
  release, SBOM, and release-gate digests.
- `run-public-smoke.sh` makes bounded anonymous requests and retains only status,
  type, size, policy booleans, and response hashes.
- `record-result.sh` appends attempts and copies sanitized, hashed evidence into
  the private report directory.
- `finalize-report.sh` changes report state only after strict validation passes.

The scripts do not claim that browser, account, data-rights, voice, database,
forge, log, failure-injection, or accessibility checks happened. An operator or
owned test runner must execute those cases and attach bounded proof.

## Meet the prerequisites

Start only after Gates 12 and 13 produce all of the following:

- A dedicated staging project, network, database instance, web lane,
  distributed fleet, deployer, identities, secrets, buckets, and registry.
- A clean `main` commit with an exact local release-gate receipt.
- An immutable candidate directory produced by `publish-candidate.sh`.
- A completed migration classification, snapshot, copy rehearsal, migration
  receipt, and rollback-compatibility receipt for the actual staging target.
- Web and distributed nodes reporting the same candidate Git SHA and digest.
- A manifest-scoped disposable test run registered for every account,
  repository, recording, and product computer that the regression creates.

Keep the candidate directory private under `.git`. Confirm its checksum before
each use. Install `curl`, `jq`, `sha256sum`, `strings`, and a current browser test
runner on the owned test machine.

Do not start Gate 14 if the candidate changed, staging shares any production
failure domain, or the retained authenticated browser session cannot be safely
recovered.

## Prove the local harness

Run the complete network-free dry check:

```sh
ops/staging/regression.sh check
```

Expected result:

```text
Staging regression harness dry run passed (69 cases; no network requests sent).
```

Also run `mix precommit` and the exact-SHA release gate for the candidate. Do
not turn a failed local check into a staging-only exception.

## Create one report for the candidate

Choose a unique lowercase run ID. Point the generator at the exact candidate
directory:

```sh
candidate_sha=$(git rev-parse HEAD)
candidate_dir=".git/openagents/staging-candidates/$candidate_sha"
run_id="gate14-20260820-0001"

ops/staging/new-report.sh "$candidate_dir" "$run_id"
```

The report is created with mode `0600` at:

```text
.git/openagents/staging-reports/<candidate-sha>/<run-id>/
  report.json
  report.sha256
```

Do not move the working report into the source tree. Retain the final sanitized
report and evidence in the staging-only versioned evidence bucket after its
scanner and checksum pass.

Verify the draft before testing:

```sh
report=".git/openagents/staging-reports/$candidate_sha/$run_id/report.json"
ops/staging/validate-report.sh --draft "$report"
```

Confirm that the target, Git SHA, application and builder image digests,
release, SBOM, and release-gate digest match the candidate under test.

## Preserve browser and revision state

Use an incognito or isolated browser context for anonymous checks. Keep the
owned persistent staging browser profile for authenticated checks. Do not log
out that profile unless the operator has separately proved that it can be
restored without exposing a user credential.

After every deployment, hard-reload each persistent tab before testing. An
open LiveView can remain connected to a draining old revision, which makes a
new feature appear broken and invalidates revision-bound evidence. Confirm the
new revision from `/status` before the first authenticated action.

Record one UTC test window for each attempt. Do not combine evidence from an old
revision, a different image digest, or a different database state.

## Run the bounded public smoke

Write the smoke receipt outside the report, then attach it through the recorder:

```sh
smoke_root=$(mktemp -d /tmp/openagents-public-smoke.XXXXXX)
smoke_receipt="$smoke_root/public-smoke.json"

ops/staging/run-public-smoke.sh --run "$candidate_dir" "$smoke_receipt"
ops/staging/record-result.sh \
  "$report" public-001 passed public-smoke "$smoke_receipt"
```

The smoke checks `/health`, `/status`, `/api/status`, `/favicon.ico`, `/`,
`/leaderboard`, `/changelog`, `/docs`, and `/components`. JSON endpoints must
report the candidate SHA. The home response must bind the CSP nonce to the
theme bootstrap and publish the microphone permissions policy. The receipt
contains no response bodies or header values.

Use `/health` for every public Cloud Run check. Cloud Run reserves some paths
that end in `z`, so `/healthz` can return a platform `404` before the request
reaches Phoenix. The application retains `/healthz` as a compatibility alias
for direct and distributed fleet traffic.

The receipt proves all of `public-001` and only the automated portions of
`public-002` and `public-005`. Complete the configured forge, browser-policy,
cookie, origin, image, microphone, and manual browser checks before marking
those hybrid cases passed.

## Record every attempt

Attach one sanitized evidence file to each passed attempt:

```sh
ops/staging/record-result.sh \
  "$report" chat-001 passed browser-assertions /path/to/sanitized-receipt.json
```

For a failure or block, put the bounded explanation in a mode-`0600` text file.
Do not include a prompt, message, transcript, memory value, credential, raw
request, or personal data:

```sh
reason_file=$(mktemp /tmp/openagents-staging-reason.XXXXXX)
chmod 600 "$reason_file"
# Write a short operational cause into $reason_file with an editor.

ops/staging/record-result.sh \
  "$report" chat-001 failed browser-assertions \
  /path/to/sanitized-receipt.json "$reason_file"
```

After correction, record a new passed attempt. The first failure and its proof
remain in the attempt list:

```sh
ops/staging/record-result.sh \
  "$report" chat-001 passed browser-assertions \
  /path/to/corrective-verification.json
```

Mark a case not applicable only when the architecture makes the case genuinely
inapplicable, not when a dependency is unavailable or a check is inconvenient:

```sh
ops/staging/record-result.sh \
  "$report" CASE_ID not_applicable /path/to/bounded-reason.txt
```

The recorder scans the source, copies it as mode `0600`, computes its SHA-256,
updates the report atomically, and reruns draft validation. It refuses edits to
a regression-passed or complete report. Adding a corrective attempt to a
`recorded` report returns it to `draft` and preserves the previous attempts.

## Execute groups in dependency order

Run the groups in this order so a lower-level failure does not contaminate a
higher-level result:

| Order | Group | Cases | Primary proof |
| --- | --- | ---: | --- |
| 1 | Public and browser | 6 | Public smoke, anonymous browser, policy and accessibility receipts |
| 2 | Authentication | 5 | OAuth boundary tests, retained-session checks, account-state receipts |
| 3 | Typed chat and Markdown | 6 | Browser assertions, persisted turn receipts, bounded failure checks |
| 4 | Memory and data rights | 6 | UI assertions, export/reset/delete receipts, scoped database counts |
| 5 | Voice and recording | 12 | Fake-media results, request statuses, generation and recording receipts |
| 6 | Leaderboard and admin | 6 | Anonymous field checks, authorization checks, operator receipts |
| 7 | Issues and Projects | 6 | API and LiveView checks, cross-repository refusal receipts |
| 8 | Computers and work | 5 | Pairing lifecycle, real harmless job, restart and cleanup receipts |
| 9 | Forge and deployment | 11 | Git, WAL, build, rollback, relup, and rolling-replacement receipts |
| 10 | Logs and truth | 6 | Exact-window log summary, content scan, and bounded database truth |

Use `ops/staging/regression-matrix.json` as the canonical case inventory. Never
delete, rename, or merge cases in a report. Change the versioned matrix and its
contract tests in a dedicated source commit if the product contract changes.

## Exercise authenticated and destructive flows safely

Use only staging-owned accounts and resources registered to the current run.
Confirm the authenticated owner before export, reset, or deletion. Verify the
reset through `#reset-conversation-form`, then confirm one greeting and no
remaining message or memory rows for that owner. Never infer deletion from the
UI alone.

Run cross-account and cross-repository checks with two staging-owned identities.
Prove refusal with statuses and bounded row counts. Do not capture access tokens,
session cookies, OAuth codes, CSRF values, response bodies, or database values.

For computer tests, keep claim and computer credentials only in process memory.
Use a harmless disposable project, revoke the computer, prove replay refusal,
and remove its ephemeral controller home and project before cleanup.

## Exercise voice with fake media

Use an owned browser harness with a synthetic audio fixture and fake-media
browser flags. Store authentication in the private browser profile, not in the
script or evidence. Only one tab may own the active voice call.

Assert these observable outcomes:

- `#voice-start`, `#voice-status`, and `#voice-end` remain usable.
- The call progresses through listening, speaking, interruption, and clean end.
- Call creation returns `201` and final deletion returns `204`.
- Typed input during voice persists without ending the call or starting a
  competing typed response.
- The next spoken response can use the injected typed content.
- Recording disclosure exists before microphone access.
- Recording chunks and completion use the admitted generation.
- An operator can play the assembled recording and an unauthorized account
  cannot.
- Recorder failure leaves both live voice and typed chat usable.

Refresh chat after the harness exits and verify durable transcript items and
interruption markers. Evidence should contain selector states, request status
codes, timestamps, sizes, generations, and hashes—not audio, transcript text,
SDP, provider events, or cookies. Retry a transient harness failure at most once
and preserve both attempts.

## Bind operational truth to the test window

Query logs for the exact candidate revision and UTC attempt window. Inspect
both severity errors and application error text because they can use different
log severities. Separate deployment-overlap connection noise from candidate
regressions by revision and timestamp; do not dismiss unexplained errors as
expected noise.

Export only a bounded summary with counts, revision, query window, and content
scan result. Run the evidence scanner before attachment:

```sh
ops/staging/scan-evidence.sh /path/to/sanitized-log-summary.json
```

Use direct staging database queries when the UI, cache, and persistence disagree.
Retain schema names, bounded counts, booleans, row ownership IDs hashed for the
run, and transaction timestamps. Never retain raw product columns.

## Complete the report-level evidence

Copy sanitized global receipts under the report's `evidence/` directory with
mode `0600`. Scan and hash each file, then add an evidence reference of this
shape to the matching `staging_evidence` field:

```json
{
  "path": "evidence/migration-rehearsal.json",
  "sha256": "64-lowercase-hex-characters",
  "kind": "migration-rehearsal"
}
```

Populate every field described in the
[staging evidence report contract](staging-report-template.md). Run draft
validation after each reviewable edit. The validator recomputes every referenced
file hash, rejects links and path escapes, requires mode `0400` or `0600`, and
rescans the content.

## Finalize without erasing failures

After the first complete pass, seal a report with failures or blocks as
`recorded`:

```sh
ops/staging/finalize-report.sh --recorded "$report"
```

The command refuses pending cases. Record corrective attempts as needed; each
new attempt returns the report to draft while preserving history.

When every applicable Gate 14 case passes and every common evidence field is
complete, seal the regression result:

```sh
ops/staging/finalize-report.sh --regression "$report"
```

Do not edit a regression-passed report until Gate 15 produces one complete,
self-contained report through the
[staging resilience runbook](staging-resilience.md). Attach that report as both
the failure-injection timeline and soak receipt, then seal the main report with:

```sh
ops/staging/finalize-report.sh --final "$report"
```

Verify `report.sha256`, scan the complete report directory, and upload only the
sanitized set to staging evidence storage. A passed Gate 14 report does not
authorize production.

## Clean up the disposable run

Quiesce the harness so it cannot create more resources. Preview the exact
manifest-scoped cleanup:

```sh
ops/staging/cleanup-run.sh "$run_id" check
```

Apply cleanup only after the bounded counts match the run:

```sh
ops/staging/cleanup-run.sh "$run_id" --apply
```

Prove the run manifest is empty, computer credentials no longer work, the
ephemeral controller files are gone, and retained evidence still validates.
Cleanup never converts a failed regression into a pass.
