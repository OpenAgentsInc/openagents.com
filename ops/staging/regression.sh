#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
matrix="$script_dir/regression-matrix.json"
mode=${1:-}

if [ "$mode" != check ] || [ "$#" -ne 1 ]; then
  echo "usage: ops/staging/regression.sh check" >&2
  exit 64
fi

for command_name in git jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required to check the staging regression harness" >&2
    exit 1
  fi
done

jq -e '
  .schema == "openagents.staging-regression-matrix.v1" and
  .revision == 1 and
  (.groups | type == "array" and length == 10) and
  ([.groups[].id] | length == (unique | length)) and
  ([.groups[].cases[]] | length == 69) and
  ([.groups[].cases[].id] | length == (unique | length)) and
  all(.groups[];
    (.id | type == "string" and test("^[a-z][a-z0-9_]+$")) and
    (.title | type == "string" and length > 0) and
    (.cases | type == "array" and length > 0) and
    all(.cases[];
      (.id | test("^[a-z]+-[0-9]{3}$")) and
      (.title | type == "string" and length > 0) and
      (.execution | IN("automated", "hybrid", "manual"))))
' "$matrix" >/dev/null || {
  echo "staging regression matrix contract failed" >&2
  exit 1
}

check_root=$(mktemp -d /tmp/openagents-regression-check.XXXXXX)
cleanup() {
  find "$check_root" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

dry_report="$check_root/report.json"
safe_evidence="$check_root/safe.json"
unsafe_evidence="$check_root/unsafe.txt"

"$script_dir/new-report.sh" --dry-run "$dry_report"
"$script_dir/validate-report.sh" --draft "$dry_report" >/dev/null

if "$script_dir/validate-report.sh" --regression "$dry_report" >/dev/null 2>&1; then
  echo "draft staging report unexpectedly passed regression validation" >&2
  exit 1
fi

printf '%s\n' '{"schema":"openagents.staging-safe-test.v1","status":"ok"}' >"$safe_evidence"
chmod 600 "$safe_evidence"
"$script_dir/scan-evidence.sh" "$safe_evidence" >/dev/null

credential_label=Bearer
credential_body=000000000000000000000000
printf '%s %s\n' "$credential_label" "$credential_body" >"$unsafe_evidence"
chmod 600 "$unsafe_evidence"

if "$script_dir/scan-evidence.sh" "$unsafe_evidence" >/dev/null 2>&1; then
  echo "staging evidence scanner unexpectedly accepted a credential-shaped value" >&2
  exit 1
fi

"$script_dir/run-public-smoke.sh" check >/dev/null

head_sha=$(git -C "$repo_root" rev-parse --verify HEAD)
case "$head_sha" in
  "" | *[!0-9a-f]*) echo "repository HEAD is not a Git object ID" >&2; exit 1 ;;
  *) ;;
esac

if [ "${#head_sha}" -ne 40 ]; then
  echo "repository HEAD is not a Git object ID" >&2
  exit 1
fi

echo "Staging regression harness dry run passed (69 cases; no network requests sent)."
