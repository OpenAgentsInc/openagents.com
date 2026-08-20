#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
matrix="$script_dir/resilience-matrix.json"
mode=${1:-}
report=${2:-}

case "$mode" in
  --draft | --recorded | --final) ;;
  *)
    echo "usage: ops/staging/validate-resilience-report.sh [--draft|--recorded|--final] REPORT" >&2
    exit 64
    ;;
esac

if [ "$#" -ne 2 ] || [ ! -f "$report" ]; then
  echo "REPORT must be a regular file" >&2
  exit 1
fi

for command_name in jq realpath sha256sum stat; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required to validate a staging resilience report" >&2
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
    (.evidence | type == "array" and length > 0 and all(.[]; evidence_ref));
  def valid_result($expected):
    . as $result |
    ($expected | map(select(.id == $result.id)) | .[0]) as $case |
    $case != null and
    $result.title == $case.title and
    ($result.status | IN("pending", "passed", "failed", "blocked")) and
    ($result.reason == null or ($result.reason | nonempty)) and
    ($result.attempts | type == "array" and all(.[]; valid_attempt)) and
    ($result.evidence | type == "array" and all(.[]; evidence_ref)) and
    ($result.attempts as $attempts |
      [$attempts[].ordinal] == [range(1; ($attempts | length) + 1)]) and
    (if $result.status == "pending" then
       ($result.attempts | length) == 0 and $result.reason == null
     else
       ($result.attempts | length) > 0 and
       ($result.attempts[-1].outcome == $result.status) and
       ($result.evidence | length) > 0 and
       (if $result.status == "passed" then true else ($result.reason | nonempty) end)
     end);
  def issue_valid:
    (.id | nonempty) and
    (.owner | nonempty) and
    (.severity | IN("low", "medium", "high", "critical")) and
    (.disposition | IN("resolved", "accepted_non_blocking")) and
    (if .severity | IN("high", "critical") then .disposition == "resolved" else true end);

  $matrix[0].failure_injections as $expected_failures |
  $matrix[0].soak.canaries as $expected_canaries |
  . as $report |

  .schema == "openagents.staging-resilience-report.v1" and
  .matrix_revision == $matrix[0].revision and
  (.synthetic | type == "boolean") and
  (.run_id | type == "string" and test("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")) and
  (.created_at | timestamp) and
  (.completed_at == null or (.completed_at | timestamp)) and
  .target.environment == "staging" and
  .target.base_url == "https://staging.openagents.com" and
  .target.track == "release-candidate" and
  .target.service == "openagents-staging-release" and
  (.target.project | type == "string" and test("stag"; "i")) and
  (.target.region | nonempty) and
  (.candidate.git_sha | type == "string" and test("^[0-9a-f]{40}$")) and
  (.candidate.candidate_manifest_sha256 | digest) and
  (.candidate.application_manifest_digest | manifest_digest) and
  (.candidate.application_image | endswith("@" + $report.candidate.application_manifest_digest)) and
  (.candidate.release_version | nonempty) and
  (.candidate.release_sha256 | digest) and
  (.candidate.gate14_report_sha256 | digest) and
  (.failure_injections | type == "array" and length == ($expected_failures | length)) and
  ([.failure_injections[].id] | sort) == ([$expected_failures[].id] | sort) and
  all(.failure_injections[]; valid_result($expected_failures)) and
  .soak.required_duration_seconds == $matrix[0].soak.required_duration_seconds and
  .soak.metric_sample_cadence_seconds == $matrix[0].soak.metric_sample_cadence_seconds and
  (.soak.canaries | type == "array" and length == ($expected_canaries | length)) and
  ([.soak.canaries[].id] | sort) == ([$expected_canaries[].id] | sort) and
  all(.soak.canaries[]; . as $canary |
    ($expected_canaries | map(select(.id == $canary.id)) | .[0]) as $expected |
    $canary.cadence_seconds == $expected.cadence_seconds and
    $canary.minimum_passes == $expected.minimum_passes and
    ($canary.completed_count == null or ($canary.completed_count | type == "number" and . >= 0 and floor == .)) and
    ($canary.passed_count == null or ($canary.passed_count | type == "number" and . >= 0 and floor == .)) and
    ($canary.receipt == null or ($canary.receipt | evidence_ref))) and
  (.known_issues | type == "array" and all(.[]; issue_valid)) and
  ([.. | objects | select(has("path") or has("sha256"))] | all(.[]; evidence_ref)) and
  (if $mode == "--draft" then
     .state == "draft"
   elif $mode == "--recorded" then
     .state == "recorded" and .synthetic == false and (.completed_at | timestamp) and
     all(.failure_injections[]; .status != "pending")
   else
     .state == "complete" and .synthetic == false and (.completed_at | timestamp) and
     all(.failure_injections[]; .status == "passed") and
     (.soak.started_at | timestamp) and
     (.soak.completed_at | timestamp) and
     ((.soak.completed_at | fromdateiso8601) - (.soak.started_at | fromdateiso8601) >= .soak.required_duration_seconds) and
     ((.completed_at | fromdateiso8601) >= (.soak.completed_at | fromdateiso8601)) and
     .soak.candidate_identity_stable == true and
     .soak.redeploy_count == 0 and
     (.soak.metric_sample_count | type == "number" and . >= $matrix[0].soak.minimum_metric_samples and floor == .) and
     (.soak.timeline_receipt | evidence_ref) and
     (.soak.metrics_receipt | evidence_ref) and
     all(.soak.canaries[]; . as $canary |
       ($canary.completed_count | type == "number" and . >= $canary.minimum_passes and floor == .) and
       $canary.passed_count == $canary.completed_count and
       ($canary.receipt | evidence_ref)) and
     (.soak.post_soak_smoke_receipt | evidence_ref) and
     .soak.unexplained_error_count == 0 and
     .soak.data_loss_count == 0 and
     .soak.authority_expansion_count == 0 and
     .soak.fleet_divergence_count == 0 and
     .soak.secret_leak_count == 0 and
     .soak.unexplained_restart_count == 0
   end)
' "$report" >/dev/null || {
  echo "staging resilience report does not satisfy $mode validation" >&2
  exit 1
}

report_dir=$(realpath "$(dirname -- "$report")")
refs=$(mktemp /tmp/openagents-resilience-report-refs.XXXXXX)
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
    *) echo "evidence file must use mode 0400 or 0600: $relative_path" >&2; exit 1 ;;
  esac

  "$script_dir/scan-evidence.sh" "$evidence_path" >/dev/null
done <"$refs"

echo "Staging resilience report $mode validation passed."
