#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
run_root=$(mktemp -d /tmp/openagents-baseline.XXXXXX)

cleanup() {
  rm -rf -- "$run_root"
}

trap cleanup EXIT INT TERM

if [ ! -d "$repo_root/.git" ]; then
  echo "baseline gate must run from a Git worktree" >&2
  exit 1
fi

cd "$repo_root"

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  echo "baseline gate requires a clean worktree" >&2
  exit 1
fi

git_sha=$(git rev-parse --verify HEAD)
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
started_epoch=$(date +%s)

run_stage() {
  stage_name=$1
  shift
  stage_log="$run_root/$stage_name.log"
  stage_started=$(date +%s)

  echo "Running $stage_name"

  set +e
  "$@" >"$stage_log" 2>&1
  stage_status=$?
  set -e

  cat "$stage_log"

  if [ "$stage_status" -ne 0 ]; then
    echo "$stage_name failed" >&2
    exit "$stage_status"
  fi

  stage_finished=$(date +%s)
  eval "${stage_name}_duration_seconds=$((stage_finished - stage_started))"
}

run_stage precommit env MIX_ENV=test mix precommit
run_stage coverage "$repo_root/ops/ci/coverage.sh"
run_stage release_smoke "$repo_root/ops/ci/release-smoke.sh"

if [ "$(git rev-parse --verify HEAD)" != "$git_sha" ]; then
  echo "Git HEAD changed while the baseline gate was running" >&2
  exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  echo "baseline gate left the worktree dirty" >&2
  exit 1
fi

javascript_tests=$(awk '/^ℹ tests [0-9]+$/ {value=$3} END {print value}' "$run_root/precommit.log")
default_tests=$(awk '
  /^Result: [0-9]+ passed/ {value=$2}
  /^[0-9]+ tests, 0 failures/ {value=$1}
  END {print value}
' "$run_root/precommit.log")
excluded_tests=$(awk '
  /^Result: [0-9]+ passed, [0-9]+ excluded$/ {value=$4; gsub(/,/, "", value)}
  /^[0-9]+ tests, 0 failures \([0-9]+ excluded\)$/ {value=$5; gsub(/[()]/, "", value)}
  END {print value}
' "$run_root/precommit.log")
cluster_tests=$(awk '
  /^Result: [0-9]+ passed, [0-9]+ excluded$/ {value=$2}
  /^[0-9]+ tests, 0 failures \([0-9]+ excluded\)$/ {value=$1}
  END {print value}
' "$run_root/coverage.log")
coverage_percent=$(awk -F '|' '/Total/ {value=$2} END {gsub(/[% ]/, "", value); print value}' "$run_root/coverage.log")

for parsed_value in "$javascript_tests" "$default_tests" "$excluded_tests" "$cluster_tests" "$coverage_percent"; do
  if [ -z "$parsed_value" ]; then
    echo "baseline gate could not parse a required content-free result" >&2
    exit 1
  fi
done

completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
completed_epoch=$(date +%s)
total_duration_seconds=$((completed_epoch - started_epoch))
receipt_dir="$repo_root/.git/openagents/gate-receipts"
receipt_path="$receipt_dir/$git_sha.json"
receipt_temp="$receipt_path.tmp.$$"

mkdir -p "$receipt_dir"
umask 077

cat >"$receipt_temp" <<EOF
{
  "schema": "openagents.baseline-gate.v1",
  "git_sha": "$git_sha",
  "status": "passed",
  "started_at": "$started_at",
  "completed_at": "$completed_at",
  "total_duration_seconds": $total_duration_seconds,
  "automatic_retries": 0,
  "stages": {
    "precommit": {"status": "passed", "duration_seconds": $precommit_duration_seconds},
    "coverage": {"status": "passed", "duration_seconds": $coverage_duration_seconds},
    "release_smoke": {"status": "passed", "duration_seconds": $release_smoke_duration_seconds}
  },
  "tests": {
    "javascript": $javascript_tests,
    "default": $default_tests,
    "cluster": $cluster_tests,
    "excluded_from_default": $excluded_tests
  },
  "coverage_percent": $coverage_percent
}
EOF

mv "$receipt_temp" "$receipt_path"

echo "Baseline gate passed for $git_sha"
echo "Receipt: .git/openagents/gate-receipts/$git_sha.json"
