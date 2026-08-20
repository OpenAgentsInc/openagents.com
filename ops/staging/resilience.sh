#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
matrix="$script_dir/resilience-matrix.json"
mode=${1:-}

if [ "$mode" != check ] || [ "$#" -ne 1 ]; then
  echo "usage: ops/staging/resilience.sh check" >&2
  exit 64
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to check the staging resilience harness" >&2
  exit 1
fi

jq -e '
  .schema == "openagents.staging-resilience-matrix.v1" and
  .revision == 1 and
  (.failure_injections | type == "array" and length == 11) and
  ([.failure_injections[].id] | length == (unique | length)) and
  all(.failure_injections[];
    (.id | test("^failure-[0-9]{3}$")) and
    (.title | type == "string" and length > 0)) and
  .soak.required_duration_seconds == 172800 and
  .soak.metric_sample_cadence_seconds == 300 and
  .soak.minimum_metric_samples == 576 and
  (.soak.canaries | type == "array" and length == 6) and
  ([.soak.canaries[].id] | sort) == ["git", "memory", "status", "tracker", "typed", "voice"] and
  all(.soak.canaries[]; . as $canary |
    ($canary.cadence_seconds | type == "number" and . > 0 and floor == .) and
    ($canary.minimum_passes | type == "number" and . >= (172800 / $canary.cadence_seconds) and floor == .))
' "$matrix" >/dev/null || {
  echo "staging resilience matrix contract failed" >&2
  exit 1
}

check_root=$(mktemp -d /tmp/openagents-resilience-check.XXXXXX)
cleanup() {
  find "$check_root" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

report="$check_root/report.json"
evidence="$check_root/evidence.json"

"$script_dir/new-resilience-report.sh" --dry-run "$report"
"$script_dir/validate-resilience-report.sh" --draft "$report" >/dev/null

if "$script_dir/finalize-report.sh" --final "$report" >/dev/null 2>&1; then
  echo "draft resilience report unexpectedly passed final validation" >&2
  exit 1
fi

printf '%s\n' '{"schema":"openagents.resilience-check.v1","status":"recovered"}' >"$evidence"
chmod 600 "$evidence"
"$script_dir/record-result.sh" "$report" failure-001 passed dry-run "$evidence" >/dev/null
"$script_dir/validate-resilience-report.sh" --draft "$report" >/dev/null

echo "Staging resilience harness dry run passed (11 failures; 48-hour soak; no network requests sent)."
