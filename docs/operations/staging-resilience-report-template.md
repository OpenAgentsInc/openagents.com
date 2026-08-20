# Staging resilience evidence contract

Date: 2026-08-20

Status: Current Gate 15 evidence contract

`new-resilience-report.sh` generates one report for the candidate that already
passed Gate 14. The report binds the candidate manifest, application image,
release, and Gate 14 report checksum to 11 controlled-failure results and one
48-hour soak.

## Failure results

Every failure result starts pending. A passed, failed, or blocked result requires
an attempt and sanitized evidence. Ordinals remain contiguous, and a retry
appends rather than replaces the first observation. Controlled-failure cases
cannot be not applicable.

Use `record-result.sh` to update results. It accepts both the Gate 14 and Gate 15
report schemas and selects the correct strict validator.

## Soak fields

Completion requires:

- Start and completion UTC timestamps separated by at least 172,800 seconds.
- `candidate_identity_stable` set to true and `redeploy_count` set to zero.
- At least 576 five-minute metric samples and a sanitized metric receipt.
- A sanitized soak timeline receipt.
- Exact canary IDs, cadences, minimums, completed counts, passed counts, and
  aggregate receipts.
- A full post-soak smoke receipt from the same candidate without a redeploy.
- Zero unexplained errors, data loss, authority expansion, fleet divergence,
  secret leakage, and unexplained restarts.

The canary minimums are 576 status, 96 typed, 96 memory, 96 tracker, 96 Git, and
24 fake-media voice passes.

## Known issues

Each known issue records a bounded ID, owner, severity, and disposition. Allowed
dispositions are `resolved` and `accepted_non_blocking`. High and critical
issues must be resolved. Do not put user content, raw logs, or credentials into
an issue field.

## Evidence references

Evidence references use the same contract as the Gate 14 report: relative path
under `evidence/`, lowercase SHA-256, and bounded kind. Files must be regular,
unlinked, at most 50 MiB, mode `0400` or `0600`, checksum-correct, and safe under
`scan-evidence.sh`.

The final resilience directory is self-contained. When nested under the Gate 14
report, its own `evidence/` paths continue to resolve relative to the resilience
report.

## States

- `draft` permits pending and failed controlled-failure results.
- `recorded` proves every failure case has an outcome but can retain a failure
  or block.
- `complete` requires every recovery, the full soak, all scheduled canaries,
  operational evidence, and zero unexplained harm.

Only `finalize-report.sh` changes report state. A synthetic dry-run report can
never become recorded or complete.
