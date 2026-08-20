#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
matrix="$script_dir/regression-matrix.json"
mode=${1:-}
report=${2:-}

case "$mode" in
  --draft | --recorded | --regression | --final) ;;
  *)
    echo "usage: ops/staging/validate-report.sh [--draft|--recorded|--regression|--final] REPORT" >&2
    exit 64
    ;;
esac

if [ "$#" -ne 2 ] || [ ! -f "$report" ]; then
  echo "REPORT must be a regular file" >&2
  exit 1
fi

for command_name in jq realpath sha256sum stat; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required to validate a staging report" >&2
    exit 1
  fi
done

"$script_dir/scan-evidence.sh" "$report" >/dev/null

jq -e \
  --arg mode "$mode" \
  --slurpfile matrix "$matrix" '
  def digest: type == "string" and test("^[0-9a-f]{64}$");
  def manifest_digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
  def timestamp: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
  def nonempty: type == "string" and length > 0 and length <= 500;
  def evidence_ref:
    type == "object" and
    (.path | type == "string" and test("^evidence/[A-Za-z0-9._/-]+$") and (contains("..") | not)) and
    (.sha256 | digest) and
    (.kind | nonempty);
  def valid_attempt:
    type == "object" and
    (.ordinal | type == "number" and . >= 1 and floor == .) and
    (.outcome | IN("passed", "failed", "blocked")) and
    (.started_at | timestamp) and
    (.completed_at | timestamp) and
    (.automatic_retry | type == "boolean") and
    (.explanation == null or (.explanation | nonempty)) and
    (.evidence | type == "array" and all(.[]; evidence_ref));
  def all_receipt_objects_valid:
    [.. | objects | select(has("path") or has("sha256"))] |
    all(.[]; evidence_ref);
  def common_staging_evidence_complete:
    (.staging_evidence.migration.classification | IN("empty_current", "known_prior", "already_baselined")) and
    (.staging_evidence.migration.snapshot_receipt | evidence_ref) and
    (.staging_evidence.migration.rehearsal_receipt | evidence_ref) and
    (.staging_evidence.migration.migration_versions_receipt | evidence_ref) and
    (.staging_evidence.migration.rollback_compatibility_receipt | evidence_ref) and
    (.staging_evidence.configuration_readiness_receipt | evidence_ref) and
    (.staging_evidence.local_gate.default_test_count | type == "number" and . > 0 and floor == .) and
    (.staging_evidence.local_gate.cluster_test_count | type == "number" and . > 0 and floor == .) and
    (.staging_evidence.local_gate.javascript_test_count | type == "number" and . > 0 and floor == .) and
    (.staging_evidence.local_gate.coverage_summary_receipt | evidence_ref) and
    (.staging_evidence.deployment.web_revision | nonempty) and
    (.staging_evidence.deployment.web_image_digest == .candidate.application_manifest_digest) and
    (.staging_evidence.deployment.distributed_node_release_receipt | evidence_ref) and
    (.staging_evidence.forge.build_receipt | evidence_ref) and
    (.staging_evidence.forge.deployment_receipt | evidence_ref) and
    (.staging_evidence.forge.rollback_receipt | evidence_ref) and
    (.staging_evidence.forge.relup_receipt | evidence_ref) and
    (.staging_evidence.forge.rolling_replacement_receipt | evidence_ref) and
    (.staging_evidence.sanitized_artifacts | type == "array" and length > 0 and all(.[]; evidence_ref));

  [
    $matrix[0].groups[] as $group |
    $group.cases[] |
    {id: .id, group: $group.id, title: .title, execution: .execution}
  ] as $expected |
  . as $report |

  .schema == "openagents.staging-report.v1" and
  .matrix_revision == $matrix[0].revision and
  (.synthetic | type == "boolean") and
  (.run_id | type == "string" and test("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")) and
  (.created_at | timestamp) and
  (.completed_at == null or (.completed_at | timestamp)) and
  .target.environment == "staging" and
  .target.base_url == "https://staging.openagents.com" and
  (.target.project | type == "string" and test("stag"; "i")) and
  (.target.region | nonempty) and
  (.candidate.git_sha | type == "string" and test("^[0-9a-f]{40}$")) and
  .candidate.branch == "main" and
  (.candidate.candidate_manifest_sha256 | digest) and
  (.candidate.application_manifest_digest | manifest_digest) and
  (.candidate.builder_manifest_digest | manifest_digest) and
  (.candidate.application_image | endswith("@" + $report.candidate.application_manifest_digest)) and
  (.candidate.builder_image | endswith("@" + $report.candidate.builder_manifest_digest)) and
  (.candidate.release_version | nonempty) and
  (.candidate.release_sha256 | digest) and
  (.candidate.sbom_sha256 | digest) and
  (.candidate.release_gate_sha256 | digest) and
  (.results | type == "array" and length == ($expected | length)) and
  ([.results[].id] | sort) == ([$expected[].id] | sort) and
  all(.results[]; . as $result |
    ($expected | map(select(.id == $result.id)) | .[0]) as $case |
    $result.group == $case.group and
    $result.title == $case.title and
    $result.execution == $case.execution and
    ($result.status | IN("pending", "passed", "failed", "blocked", "not_applicable")) and
    ($result.reason == null or ($result.reason | nonempty)) and
    ($result.attempts | type == "array" and all(.[]; valid_attempt)) and
    ($result.evidence | type == "array" and all(.[]; evidence_ref)) and
    ($result.attempts as $attempts |
      [$attempts[].ordinal] == [range(1; ($attempts | length) + 1)]) and
    (if $result.status == "pending" then
       ($result.attempts | length) == 0 and $result.reason == null
     elif $result.status == "not_applicable" then
       ($result.reason | nonempty)
     else
       ($result.attempts | length) > 0 and
       ($result.attempts[-1].outcome == $result.status) and
       ($result.evidence | length) > 0 and
       (if $result.status == "passed" then true else ($result.reason | nonempty) end)
     end)
  ) and
  all_receipt_objects_valid and
  (if $mode == "--draft" then
     .state == "draft"
   elif $mode == "--recorded" then
     .state == "recorded" and .synthetic == false and (.completed_at | timestamp) and
     all(.results[]; .status != "pending")
   elif $mode == "--regression" then
     .state == "regression_passed" and .synthetic == false and (.completed_at | timestamp) and
     all(.results[]; .status | IN("passed", "not_applicable")) and
     common_staging_evidence_complete
   else
     .state == "complete" and .synthetic == false and (.completed_at | timestamp) and
     all(.results[]; .status | IN("passed", "not_applicable")) and
     common_staging_evidence_complete and
     (.staging_evidence.failure_injection_timeline | type == "array" and length > 0 and all(.[]; evidence_ref)) and
     (.staging_evidence.soak_receipt | evidence_ref) and
     .staging_evidence.soak_receipt.kind == "resilience-report" and
     any(.staging_evidence.failure_injection_timeline[];
       .path == $report.staging_evidence.soak_receipt.path and
       .sha256 == $report.staging_evidence.soak_receipt.sha256 and
       .kind == "resilience-report") and
     (.staging_evidence.known_issues | type == "array" and all(.[];
       (.id | nonempty) and (.owner | nonempty) and
       (.severity | IN("low", "medium", "high", "critical")) and
       (.disposition | nonempty)))
   end)
' "$report" >/dev/null || {
  echo "staging report does not satisfy $mode validation" >&2
  exit 1
}

report_dir=$(realpath "$(dirname -- "$report")")
refs=$(mktemp /tmp/openagents-staging-report-refs.XXXXXX)
cleanup() {
  unlink "$refs" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

jq -r '
  .. | objects |
  select(has("path") and has("sha256")) |
  [.path, .sha256] | @tsv
' "$report" >"$refs"

tab=$(printf '\t')
while IFS="$tab" read -r relative_path expected_sha256; do
  [ -n "$relative_path" ] || continue

  case "$relative_path" in
    evidence/*) ;;
    *) echo "evidence reference must stay under evidence/: $relative_path" >&2; exit 1 ;;
  esac

  case "$relative_path" in
    *..* | /* | *[!A-Za-z0-9._/-]*)
      echo "unsafe evidence reference: $relative_path" >&2
      exit 1
      ;;
  esac

  evidence_path="$report_dir/$relative_path"
  if [ ! -f "$evidence_path" ] || [ -L "$evidence_path" ]; then
    echo "missing or linked evidence file: $relative_path" >&2
    exit 1
  fi

  resolved=$(realpath "$evidence_path")
  case "$resolved" in
    "$report_dir"/evidence/*) ;;
    *) echo "evidence path escapes the report directory: $relative_path" >&2; exit 1 ;;
  esac

  actual_sha256=$(sha256sum "$evidence_path" | cut -d ' ' -f 1)
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    echo "evidence checksum mismatch: $relative_path" >&2
    exit 1
  fi

  mode_bits=$(stat -c '%a' "$evidence_path" 2>/dev/null || stat -f '%Lp' "$evidence_path")
  case "$mode_bits" in
    400 | 600) ;;
    *) echo "evidence file must not grant group or world access: $relative_path" >&2; exit 1 ;;
  esac

  "$script_dir/scan-evidence.sh" "$evidence_path" >/dev/null
done <"$refs"

if [ "$mode" = --final ]; then
  resilience_relative=$(jq -r '.staging_evidence.soak_receipt.path' "$report")
  resilience_report="$report_dir/$resilience_relative"
  "$script_dir/validate-resilience-report.sh" --final "$resilience_report" >/dev/null

  main_candidate_sha=$(jq -r '.candidate.git_sha' "$report")
  resilience_candidate_sha=$(jq -r '.candidate.git_sha' "$resilience_report")
  main_image_digest=$(jq -r '.candidate.application_manifest_digest' "$report")
  resilience_image_digest=$(jq -r '.candidate.application_manifest_digest' "$resilience_report")

  if [ "$main_candidate_sha" != "$resilience_candidate_sha" ] ||
     [ "$main_image_digest" != "$resilience_image_digest" ]; then
    echo "resilience report does not identify the Gate 14 candidate" >&2
    exit 1
  fi
fi

echo "Staging report $mode validation passed."
