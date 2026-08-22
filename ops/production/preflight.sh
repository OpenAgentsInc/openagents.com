#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
production_project=${OPENAGENTS_PRODUCTION_PROJECT_ID:-}
staging_report=${OPENAGENTS_STAGING_REPORT:-}
resilience_report=${OPENAGENTS_STAGING_RESILIENCE_REPORT:-}
git_sha=$(git -C "$repo_root" rev-parse --verify HEAD)
git_common_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)
candidate="$git_common_dir/openagents/staging-candidates/$git_sha/candidate-manifest.json"
isolation="$git_common_dir/openagents/staging-isolation/$git_sha.json"
rehearsal="$git_common_dir/openagents/production-rehearsal/$git_sha.json"
run_root=$(mktemp -d /tmp/openagents-production-preflight.XXXXXX)

cleanup() {
  find "$run_root" -depth -delete
}

trap cleanup EXIT INT TERM

: "${production_project:?OPENAGENTS_PRODUCTION_PROJECT_ID is required}"
: "${staging_report:?OPENAGENTS_STAGING_REPORT is required}"
: "${resilience_report:?OPENAGENTS_STAGING_RESILIENCE_REPORT is required}"

if [ "$production_project" != "openagentsgemini" ]; then
  echo "production project must be openagentsgemini" >&2
  exit 1
fi

for command_name in curl gcloud git jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required" >&2
    exit 1
  fi
done

cd "$repo_root"

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  echo "production preflight requires a clean worktree" >&2
  exit 1
fi

if ! git merge-base --is-ancestor "$git_sha" refs/remotes/origin/main; then
  echo "production candidate must remain in the fetched origin/main history" >&2
  exit 1
fi

ops/ci/gate.sh --verify >/dev/null

for required_file in "$candidate" "$isolation" "$rehearsal" "$staging_report" "$resilience_report"; do
  if [ ! -f "$required_file" ]; then
    echo "production preflight evidence is incomplete" >&2
    exit 1
  fi
done

application_digest=$(
  jq -er --arg sha "$git_sha" '
    select(.git_sha == $sha) |
    .images.application.manifest_digest |
    select(test("^sha256:[0-9a-f]{64}$"))
  ' "$candidate"
)

jq -e --arg sha "$git_sha" '
  .schema == "openagents.staging-isolation.v1" and
  .git_sha == $sha and
  .status == "passed"
' "$isolation" >/dev/null

ops/staging/validate-report.sh --final "$staging_report" >/dev/null
ops/staging/validate-resilience-report.sh --final "$resilience_report" >/dev/null

jq -e \
  --arg sha "$git_sha" \
  --arg digest "$application_digest" \
  --slurpfile resilience "$resilience_report" '
  .candidate.git_sha == $sha and
  .candidate.application_manifest_digest == $digest and
  $resilience[0].candidate.git_sha == $sha and
  $resilience[0].candidate.application_manifest_digest == $digest
' "$staging_report" >/dev/null

jq -e --arg sha "$git_sha" --arg digest "$application_digest" '
  .schema == "openagents.production-migration-rehearsal.v1" and
  .git_sha == $sha and
  .application_image_digest == $digest and
  .status == "passed" and
  .backup_status == "SUCCESSFUL" and
  .classification_before == "prior" and
  .classification_after == "prior_baselined" and
  .baseline_entries_present == 14 and
  .missing_facts == 0 and
  .candidate_startup == "passed" and
  .last_known_good_startup == "passed" and
  .counts_match == true and
  .integrity_checks == "passed"
' "$rehearsal" >/dev/null

gcloud auth print-access-token >/dev/null
gcloud sql instances describe sarah-postgres \
  --project="$production_project" --format=json >"$run_root/sql.json"
gcloud sql backups list --instance=sarah-postgres \
  --project="$production_project" --format=json >"$run_root/backups.json"
gcloud compute instances list --project="$production_project" \
  --filter='name~^sarah-fleet-' --format=json >"$run_root/fleet.json"
gcloud compute backend-services get-health sarah-backend --global \
  --project="$production_project" --format=json >"$run_root/backend.json"
curl --fail --silent --show-error --max-time 10 \
  https://openagents.com/api/status >"$run_root/status.json"

jq -e '
  .state == "RUNNABLE" and
  .settings.backupConfiguration.enabled == true and
  .settings.backupConfiguration.pointInTimeRecoveryEnabled == true and
  .settings.deletionProtectionEnabled == true
' "$run_root/sql.json" >/dev/null

jq -e '
  any(.[];
    .status == "SUCCESSFUL" and
    .type == "ON_DEMAND" and
    ((.endTime | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= (now - 86400))
  )
' "$run_root/backups.json" >/dev/null

jq -e '
  [
    .[] |
    select(.name == "sarah-fleet-1" or .name == "sarah-fleet-2" or .name == "sarah-fleet-3")
  ] as $fleet |
  ($fleet | length) == 3 and
  all($fleet[]; .status == "RUNNING")
' "$run_root/fleet.json" >/dev/null

jq -e '
  [.. | objects | .healthState? | select(. != null)] as $states |
  ($states | length) == 3 and all($states[]; . == "HEALTHY")
' "$run_root/backend.json" >/dev/null

jq -e '
  .cluster.beam == 3 and
  .cluster.raft == 3 and
  .cluster.quorum == true
' "$run_root/status.json" >/dev/null

echo "Production preflight passed for $git_sha"
