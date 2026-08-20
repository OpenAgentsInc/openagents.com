#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
staging_project=${OPENAGENTS_STAGING_PROJECT_ID:-}
production_project=${OPENAGENTS_PRODUCTION_PROJECT_ID:-}
git_sha=$(git -C "$repo_root" rev-parse --verify HEAD)
receipt_root="$repo_root/.git/openagents/staging-isolation"
receipt_path="$receipt_root/$git_sha.json"

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

for command_name in gcloud git jq sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required" >&2
    exit 1
  fi
done

gcloud auth print-access-token >/dev/null

run_root=$(mktemp -d /tmp/openagents-staging-isolation.XXXXXX)
cleanup() {
  find "$run_root" -depth -delete
}
trap cleanup EXIT INT TERM

staging_number=$(gcloud projects describe "$staging_project" --format='value(projectNumber)')
production_number=$(gcloud projects describe "$production_project" --format='value(projectNumber)')

if [ "$staging_number" = "$production_number" ]; then
  echo "staging and production resolve to the same project number" >&2
  exit 1
fi

gcloud sql instances list --project="$staging_project" --format=json >"$run_root/sql.json"
gcloud sql users list --project="$staging_project" \
  --instance=openagents-staging-postgres --format=json >"$run_root/sql-users.json"
gcloud compute instances list --project="$staging_project" --format=json >"$run_root/instances.json"
gcloud storage buckets list --project="$staging_project" --format=json >"$run_root/buckets.json"
gcloud secrets list --project="$staging_project" --format=json >"$run_root/secrets.json"
gcloud iam service-accounts list --project="$staging_project" --format=json >"$run_root/accounts.json"
gcloud dns managed-zones list --project="$staging_project" --format=json >"$run_root/dns.json"
gcloud compute networks list --project="$staging_project" --format=json >"$run_root/networks.json"
gcloud projects get-iam-policy "$staging_project" --format=json >"$run_root/staging-iam.json"
gcloud iam service-accounts list --project="$production_project" --format=json >"$run_root/production-accounts.json"

for slot in openagents-staging-scv-codex-operator-1 openagents-staging-scv-codex-operator-2; do
  gcloud secrets get-iam-policy "$slot" --project="$staging_project" --format=json \
    >"$run_root/$slot-iam.json"
done

jq -e '
  length == 1 and
  .[0].name == "openagents-staging-postgres" and
  .[0].state == "RUNNABLE" and
  ([.[0].ipAddresses[]? | select(.type == "PRIMARY")] | length) == 0 and
  .[0].settings.userLabels.environment == "staging"
' "$run_root/sql.json" >/dev/null

jq -e '
  any(
    .[];
    .name == "openagents_staging" and
    .kind == "sql#user" and
    .instance == "openagents-staging-postgres" and
    .host == ""
  )
' "$run_root/sql-users.json" >/dev/null

jq -e '
  [
    .[] |
    select(.labels.environment == "staging" and .labels.lane == "distributed")
  ] as $fleet |
  [
    .[] |
    select(.labels.environment == "staging" and .labels.lane == "deployer")
  ] as $deployer |
  ($fleet | length) == 3 and
  all($fleet[]; ([.networkInterfaces[].accessConfigs[]?] | length) == 0) and
  ($deployer | length) == 1 and
  all($deployer[]; ([.networkInterfaces[].accessConfigs[]?] | length) == 0) and
  ([$fleet[].name] | sort) == [
    "openagents-fleet-1",
    "openagents-fleet-2",
    "openagents-fleet-3"
  ]
' "$run_root/instances.json" >/dev/null

jq -e --arg project "$staging_project" '
  [.[].name] as $names |
  all([
    "\($project)-openagents-artifacts",
    "\($project)-openagents-evidence",
    "\($project)-openagents-forge-wal",
    "\($project)-openagents-recordings"
  ][]; . as $required | $names | index($required))
' "$run_root/buckets.json" >/dev/null

jq -e '
  [.[].name | split("/")[-1]] as $names |
  all([
    "openagents-staging-builder-config",
    "openagents-staging-database-url",
    "openagents-staging-fleet-database-url",
    "openagents-staging-fleet-config",
    "openagents-staging-forge-operator-token",
    "openagents-staging-github-client-secret",
    "openagents-staging-github-vault-active",
    "openagents-staging-github-vault-previous",
    "openagents-staging-openai-api-key",
    "openagents-staging-release-cookie",
    "openagents-staging-scv-codex-operator-1",
    "openagents-staging-scv-codex-operator-2",
    "openagents-staging-secret-key-base",
    "openagents-staging-voice-recording-key",
    "openagents-staging-web-config"
  ][]; . as $required | $names | index($required))
' "$run_root/secrets.json" >/dev/null

web_member="serviceAccount:openagents-staging-web@$staging_project.iam.gserviceaccount.com"

for slot in openagents-staging-scv-codex-operator-1 openagents-staging-scv-codex-operator-2; do
  jq -e --arg member "$web_member" '
    any(.bindings[]?; .role == "roles/secretmanager.secretVersionAdder" and (.members | index($member))) and
    any(.bindings[]?; .role == "roles/secretmanager.secretAccessor" and (.members | index($member)))
  ' "$run_root/$slot-iam.json" >/dev/null
done

jq -e '
  [.[].email | split("@") | first] as $names |
  all([
    "openagents-staging-deployer",
    "openagents-staging-fleet",
    "openagents-staging-web"
  ][]; . as $required | $names | index($required))
' "$run_root/accounts.json" >/dev/null

jq -e 'any(.[]; .name == "openagents-staging-internal" and .visibility == "private")' \
  "$run_root/dns.json" >/dev/null
jq -e 'any(.[]; .name == "openagents-staging")' "$run_root/networks.json" >/dev/null

jq -n \
  --slurpfile policy "$run_root/staging-iam.json" \
  --slurpfile production "$run_root/production-accounts.json" '
    [$production[0][].email | "serviceAccount:" + .] as $production_members |
    [$policy[0].bindings[].members[]?] as $staging_members |
    [$staging_members[] | select(. as $member | $production_members | index($member))] |
    length == 0
  ' | jq -e . >/dev/null

project_fingerprint=$(printf '%s' "$staging_project" | sha256sum | cut -d ' ' -f 1)
production_fingerprint=$(printf '%s' "$production_project" | sha256sum | cut -d ' ' -f 1)
mkdir -p "$receipt_root"
umask 077

jq -n \
  --arg sha "$git_sha" \
  --arg staging "$project_fingerprint" \
  --arg production "$production_fingerprint" '
  {
    schema: "openagents.staging-isolation.v1",
    git_sha: $sha,
    status: "passed",
    staging_project_fingerprint: $staging,
    production_project_fingerprint: $production,
    checks: {
      distinct_projects: "passed",
      private_database_instance: "passed",
      staging_database_role: "passed",
      three_private_fleet_nodes: "passed",
      staging_buckets: "passed",
      staging_secrets: "passed",
      scv_codex_credential_slots: "passed",
      split_service_accounts: "passed",
      private_dns_and_network: "passed",
      no_production_service_accounts: "passed"
    }
  }
' >"$receipt_path"

echo "Staging isolation validation passed for $git_sha"
echo "Receipt: .git/openagents/staging-isolation/$git_sha.json"
