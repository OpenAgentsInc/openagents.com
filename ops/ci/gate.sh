#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
receipt_root="$repo_root/.git/openagents/release-gate-receipts"
required_stages='compile precommit cluster javascript direct_transaction relup version_chain interrupted_install rolling_replacement contracts release_smoke'
mode=${1:-run}

if [ ! -d "$repo_root/.git" ]; then
  echo "release gate must run from a Git worktree" >&2
  exit 1
fi

git_sha=$(git -C "$repo_root" rev-parse --verify HEAD)
receipt_path="$receipt_root/$git_sha.json"

verify_receipt() {
  [ -f "$receipt_path" ] || return 1

  jq -e \
    --arg sha "$git_sha" \
    --arg stages "$required_stages" '
      .schema == "openagents.release-gate.v1" and
      .git_sha == $sha and
      .status == "passed" and
      ([($stages | split(" "))[] as $stage | .stages[$stage].status == "passed"] | all)
    ' "$receipt_path" >/dev/null
}

case "$mode" in
  --verify)
    if verify_receipt; then
      echo "Release gate receipt is valid for $git_sha"
      exit 0
    fi

    echo "no complete release gate receipt exists for $git_sha" >&2
    exit 1
    ;;

  --force | run) ;;

  *)
    echo "usage: ops/ci/gate.sh [--force|--verify]" >&2
    exit 64
    ;;
esac

if [ "$mode" != "--force" ] && verify_receipt; then
  echo "Release gate already passed for $git_sha"
  exit 0
fi

if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]; then
  echo "release gate requires a clean worktree" >&2
  exit 1
fi

if [ "${OPENAGENTS_RELEASE_SMOKE_DISPOSABLE:-}" != "1" ]; then
  echo "set OPENAGENTS_RELEASE_SMOKE_DISPOSABLE=1 for a disposable database" >&2
  exit 1
fi

if [ -z "${OPENAGENTS_RELEASE_SMOKE_DATABASE_URL:-}" ]; then
  echo "OPENAGENTS_RELEASE_SMOKE_DATABASE_URL is required" >&2
  exit 1
fi

for command_name in jq mix npm; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required for the release gate" >&2
    exit 1
  fi
done

run_root=$(mktemp -d /tmp/openagents-release-gate.XXXXXX)
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
started_epoch=$(date +%s)

cleanup() {
  find "$run_root" -depth -delete
}

trap cleanup EXIT INT TERM

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

cd "$repo_root"

run_stage compile env MIX_ENV=test mix compile --warnings-as-errors
run_stage precommit env MIX_ENV=test mix precommit
run_stage cluster env MIX_ENV=test mix test --warnings-as-errors --only cluster
run_stage javascript npm --prefix assets test
run_stage direct_transaction env MIX_ENV=test mix test --warnings-as-errors \
  test/openagents/forge/deployment_node_test.exs \
  test/openagents/forge/deployment_cluster_test.exs \
  test/openagents/forge/hot_loader_test.exs \
  test/openagents/forge/boot_converge_test.exs
run_stage relup ops/relup-proof/run.sh
run_stage version_chain env \
  OPENAGENTS_RELUP_PROOF_DISPOSABLE=1 \
  OPENAGENTS_RELUP_PROOF_DATABASE_URL="$OPENAGENTS_RELEASE_SMOKE_DATABASE_URL" \
  ops/relup-proof/version-chain.sh
run_stage interrupted_install env \
  OPENAGENTS_RELUP_PROOF_DISPOSABLE=1 \
  OPENAGENTS_RELUP_PROOF_DATABASE_URL="$OPENAGENTS_RELEASE_SMOKE_DATABASE_URL" \
  ops/relup-proof/kill-during-install.sh
run_stage rolling_replacement env MIX_ENV=test mix test --warnings-as-errors \
  test/openagents/forge/rolling_replacement_test.exs
run_stage contracts ops/ci/contracts.sh
run_stage release_smoke ops/ci/release-smoke.sh

if [ "$(git rev-parse --verify HEAD)" != "$git_sha" ]; then
  echo "Git HEAD changed while the release gate was running" >&2
  exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  echo "release gate left the worktree dirty" >&2
  exit 1
fi

completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
completed_epoch=$(date +%s)
total_duration_seconds=$((completed_epoch - started_epoch))
receipt_temp="$receipt_path.tmp.$$"

mkdir -p "$receipt_root"
umask 077

cat >"$receipt_temp" <<EOF
{
  "schema": "openagents.release-gate.v1",
  "git_sha": "$git_sha",
  "status": "passed",
  "started_at": "$started_at",
  "completed_at": "$completed_at",
  "total_duration_seconds": $total_duration_seconds,
  "automatic_retries": 0,
  "stages": {
    "compile": {"status": "passed", "duration_seconds": $compile_duration_seconds},
    "precommit": {"status": "passed", "duration_seconds": $precommit_duration_seconds},
    "cluster": {"status": "passed", "duration_seconds": $cluster_duration_seconds},
    "javascript": {"status": "passed", "duration_seconds": $javascript_duration_seconds},
    "direct_transaction": {"status": "passed", "duration_seconds": $direct_transaction_duration_seconds},
    "relup": {"status": "passed", "duration_seconds": $relup_duration_seconds},
    "version_chain": {"status": "passed", "duration_seconds": $version_chain_duration_seconds},
    "interrupted_install": {"status": "passed", "duration_seconds": $interrupted_install_duration_seconds},
    "rolling_replacement": {"status": "passed", "duration_seconds": $rolling_replacement_duration_seconds},
    "contracts": {"status": "passed", "duration_seconds": $contracts_duration_seconds},
    "release_smoke": {"status": "passed", "duration_seconds": $release_smoke_duration_seconds}
  }
}
EOF

mv "$receipt_temp" "$receipt_path"

echo "Release gate passed for $git_sha"
echo "Receipt: .git/openagents/release-gate-receipts/$git_sha.json"
