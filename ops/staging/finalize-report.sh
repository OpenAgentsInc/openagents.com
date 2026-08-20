#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mode=${1:-}
report=${2:-}

case "$mode" in
  --recorded) state=recorded ;;
  --regression) state=regression_passed ;;
  --final) state=complete ;;
  *)
    echo "usage: ops/staging/finalize-report.sh [--recorded|--regression|--final] REPORT" >&2
    exit 64
    ;;
esac

if [ "$#" -ne 2 ] || [ ! -f "$report" ] || [ -L "$report" ]; then
  echo "REPORT must be a regular, unlinked file" >&2
  exit 1
fi

for command_name in jq sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required to finalize a staging report" >&2
    exit 1
  fi
done

report_schema=$(jq -r '.schema // empty' "$report")
case "$report_schema" in
  openagents.staging-report.v1)
    validator="$script_dir/validate-report.sh"
    ;;
  openagents.staging-resilience-report.v1)
    validator="$script_dir/validate-resilience-report.sh"
    if [ "$mode" = --regression ]; then
      echo "a resilience report supports only --recorded and --final" >&2
      exit 1
    fi
    ;;
  *)
    echo "REPORT has an unsupported schema" >&2
    exit 1
    ;;
esac

report_dir=$(CDPATH= cd -- "$(dirname -- "$report")" && pwd)
report_temp=$(mktemp "$report_dir/.report.XXXXXX")
cleanup() {
  unlink "$report_temp" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg state "$state" --arg completed_at "$completed_at" '
  .state = $state |
  .completed_at = $completed_at
' "$report" >"$report_temp"
chmod 600 "$report_temp"

"$validator" "$mode" "$report_temp" >/dev/null || {
  echo "report remains unchanged because $mode validation failed" >&2
  exit 1
}

mv "$report_temp" "$report"
report_temp=
report_sha256=$(sha256sum "$report" | cut -d ' ' -f 1)
printf '%s  report.json\n' "$report_sha256" >"$report_dir/report.sha256"
chmod 600 "$report_dir/report.sha256"

echo "Staging report finalized as $state."
