# Staging evidence report contract

Date: 2026-08-20

Status: Current Gate 14 and Gate 15 evidence contract

`ops/staging/new-report.sh` generates the machine-readable report template from
one immutable candidate and the versioned 69-case regression matrix. Keep the
working report private under `.git/openagents/staging-reports/`; retain only a
sanitized, checksummed result in staging evidence storage.

## Report identity

The generator fixes these values. Do not edit them:

- Schema and matrix revision.
- Run ID, creation time, staging target, project, and region.
- Git SHA and `main` branch.
- Candidate-manifest checksum.
- Application and builder image references and manifest digests.
- Release version and checksum.
- SBOM and exact-SHA release-gate checksums.

The application and builder references must end in their recorded manifest
digests. Tags alone are not evidence.

## Result contract

The generator creates one result for each matrix case. Each result keeps its
group, title, execution class, status, reason, attempts, and aggregate evidence.

Allowed statuses are:

- `pending`: no attempt or reason exists.
- `passed`: the last attempt passed and evidence exists.
- `failed`: the last attempt failed, evidence exists, and a reason exists.
- `blocked`: the last attempt was blocked, evidence exists, and a reason exists.
- `not_applicable`: a bounded architectural reason exists.

Attempt ordinals start at 1 and remain contiguous. Every retry appends an
attempt; it never replaces the failed observation. Each attempt records UTC
start and completion timestamps, outcome, retry classification, bounded
explanation, and evidence references.

Use `record-result.sh` instead of hand-editing result arrays.

## Common staging evidence

Gate 14 regression finalization requires all of these fields:

| Field | Required value |
| --- | --- |
| `migration.classification` | `empty_current`, `known_prior`, or `already_baselined` |
| `migration.snapshot_receipt` | Sanitized pre-migration snapshot receipt |
| `migration.rehearsal_receipt` | Disposable-copy rehearsal receipt |
| `migration.migration_versions_receipt` | Exact applied-version receipt |
| `migration.rollback_compatibility_receipt` | Last-known-good compatibility receipt |
| `configuration_readiness_receipt` | Redacted staging-only configuration result |
| `local_gate.default_test_count` | Positive default-suite test count |
| `local_gate.cluster_test_count` | Positive cluster-suite test count |
| `local_gate.javascript_test_count` | Positive browser JavaScript test count |
| `local_gate.coverage_summary_receipt` | Merged bounded coverage receipt |
| `deployment.web_revision` | Exact staging web revision name |
| `deployment.web_image_digest` | Candidate application manifest digest |
| `deployment.distributed_node_release_receipt` | Same-SHA fleet identity receipt |
| `forge.build_receipt` | Immutable builder input and artifact receipt |
| `forge.deployment_receipt` | Transactional fleet deployment receipt |
| `forge.rollback_receipt` | Complete rollback receipt |
| `forge.relup_receipt` | Upgrade, downgrade, and re-upgrade receipt |
| `forge.rolling_replacement_receipt` | Drain-bounded replacement receipt |
| `sanitized_artifacts` | One or more sanitized screenshots, recordings, or UI receipts |

An evidence reference contains only a relative `evidence/` path, SHA-256, and
short kind. Referenced files must be regular, unlinked, mode `0400` or `0600`,
inside the report directory, checksum-correct, no larger than 50 MiB, and safe
under `scan-evidence.sh`.

## Gate 15 evidence

Final completion nests one complete report produced by the
[staging resilience runbook](staging-resilience.md). Add the same
`resilience-report` evidence reference to the failure-injection timeline and
soak receipt. The main validator reruns the nested final validator and compares
its candidate SHA and image digest with Gate 14.

The resilience report proves:

- All 11 controlled-failure cases and their retry histories.
- At least 48 hours without a redeploy.
- Scheduled typed, memory, voice, tracker, Git, and status canaries.
- Five-minute resource samples and a post-soak smoke.
- Every known issue with ID, owner, severity, and disposition.

An empty known-issue list is valid only when review found no issues. A failure,
retry, crash, stale row, divergent node, leak, or content-bearing log must not
disappear from the timeline because it was later corrected.

## Report states

The validator recognizes four states:

| State | Validator | Meaning |
| --- | --- | --- |
| `draft` | `--draft` | Work is in progress; pending and failed cases may exist |
| `recorded` | `--recorded` | Every case has an outcome; failures or blocks may remain |
| `regression_passed` | `--regression` | Every applicable Gate 14 case passed and common evidence is complete |
| `complete` | `--final` | Gate 14, failure injection, and the 48-hour soak all passed |

Only `finalize-report.sh` should change the state and completion timestamp. It
validates a temporary copy before replacing the report and recomputes
`report.sha256`.

## Prohibited content

Never retain session cookies, OAuth codes, access or refresh tokens, database
passwords, machine credentials, provider keys, private keys, authenticated
database URLs, raw prompts, messages, transcripts, memory values, tool payloads,
SDP, audio, or private administrative content.

Prefer counts, booleans, status codes, timestamps, bounded IDs, digests, and
content hashes. A passing scanner reduces accidental disclosure; it does not
replace human review.
