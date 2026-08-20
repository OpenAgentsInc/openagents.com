#!/bin/sh
set -eu

run_id=${1:-}
mode=${2:-check}
staging_project=${OPENAGENTS_STAGING_PROJECT_ID:-}
production_project=${OPENAGENTS_PRODUCTION_PROJECT_ID:-}
zone=${OPENAGENTS_STAGING_ZONE:-us-central1-a}

: "${staging_project:?OPENAGENTS_STAGING_PROJECT_ID is required}"
: "${production_project:?OPENAGENTS_PRODUCTION_PROJECT_ID is required}"

case "$staging_project" in
  *stag*) ;;
  *) echo "staging project ID must contain 'stag'" >&2; exit 1 ;;
esac

if [ "$staging_project" = "$production_project" ]; then
  echo "staging and production project IDs must differ" >&2
  exit 1
fi

case "$run_id" in
  *[!a-z0-9-]* | "") echo "run ID must contain only lowercase letters, numbers, and hyphens" >&2; exit 64 ;;
esac

run_id_length=${#run_id}
if [ "$run_id_length" -lt 8 ] || [ "$run_id_length" -gt 64 ]; then
  echo "run ID must contain 8 through 64 characters" >&2
  exit 64
fi

case "$run_id" in
  [a-z0-9]*) ;;
  *) echo "run ID must start with a lowercase letter or number" >&2; exit 64 ;;
esac

case "$mode" in
  check) action=check ;;
  --apply) action=apply ;;
  *) echo "usage: ops/staging/cleanup-run.sh RUN_ID [check|--apply]" >&2; exit 64 ;;
esac

for command_name in gcloud; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required" >&2
    exit 1
  fi
done

gcloud auth print-access-token >/dev/null

remote_expression="IO.puts(OpenAgents.StagingCleanup.command!(\"$run_id\", \"$action\"))"
remote_command="sudo docker exec openagents /app/bin/openagents eval '$remote_expression'"

gcloud compute ssh openagents-fleet-1 \
  --project="$staging_project" \
  --zone="$zone" \
  --tunnel-through-iap \
  --quiet \
  --command="$remote_command"
