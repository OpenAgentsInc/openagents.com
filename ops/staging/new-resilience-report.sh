#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
matrix="$script_dir/resilience-matrix.json"
mode=${1:-}
umask 077

usage() {
  echo "usage: ops/staging/new-resilience-report.sh CANDIDATE_DIRECTORY GATE14_REPORT RUN_ID" >&2
  echo "       ops/staging/new-resilience-report.sh --dry-run OUTPUT" >&2
  exit 64
}

for command_name in git jq sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required to create a staging resilience report" >&2
    exit 1
  fi
done

generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

write_report() {
  candidate_manifest=$1
  candidate_manifest_sha256=$2
  gate14_sha256=$3
  run_id=$4
  synthetic=$5
  output=$6

  jq -n \
    --slurpfile matrix "$matrix" \
    --slurpfile candidate "$candidate_manifest" \
    --arg candidate_manifest_sha256 "$candidate_manifest_sha256" \
    --arg gate14_sha256 "$gate14_sha256" \
    --arg run_id "$run_id" \
    --arg created_at "$generated_at" \
    --argjson synthetic "$synthetic" '
    ($matrix[0]) as $matrix |
    ($candidate[0]) as $candidate |
    {
      schema: "openagents.staging-resilience-report.v1",
      matrix_revision: $matrix.revision,
      state: "draft",
      synthetic: $synthetic,
      run_id: $run_id,
      created_at: $created_at,
      completed_at: null,
      target: {
        environment: "staging",
        base_url: "https://staging.openagents.com",
        track: "release-candidate",
        service: "openagents-staging-release",
        project: $candidate.target.project,
        region: $candidate.target.region
      },
      candidate: {
        git_sha: $candidate.git_sha,
        candidate_manifest_sha256: $candidate_manifest_sha256,
        application_image: $candidate.images.application.reference,
        application_manifest_digest: $candidate.images.application.manifest_digest,
        release_version: $candidate.release.version,
        release_sha256: $candidate.release.sha256,
        gate14_report_sha256: $gate14_sha256
      },
      failure_injections: [
        $matrix.failure_injections[] |
        {
          id: .id,
          title: .title,
          status: "pending",
          reason: null,
          attempts: [],
          evidence: []
        }
      ],
      soak: {
        required_duration_seconds: $matrix.soak.required_duration_seconds,
        started_at: null,
        completed_at: null,
        candidate_identity_stable: null,
        redeploy_count: null,
        metric_sample_cadence_seconds: $matrix.soak.metric_sample_cadence_seconds,
        metric_sample_count: null,
        timeline_receipt: null,
        metrics_receipt: null,
        canaries: [
          $matrix.soak.canaries[] |
          {
            id: .id,
            cadence_seconds: .cadence_seconds,
            minimum_passes: .minimum_passes,
            completed_count: null,
            passed_count: null,
            receipt: null
          }
        ],
        post_soak_smoke_receipt: null,
        unexplained_error_count: null,
        data_loss_count: null,
        authority_expansion_count: null,
        fleet_divergence_count: null,
        secret_leak_count: null,
        unexplained_restart_count: null
      },
      known_issues: []
    }
  ' >"$output"
}

if [ "$mode" = "--dry-run" ]; then
  [ "$#" -eq 2 ] || usage
  output=$2

  if [ -e "$output" ]; then
    echo "dry-run resilience report output already exists" >&2
    exit 1
  fi

  dry_root=$(mktemp -d /tmp/openagents-resilience-report-dry-run.XXXXXX)
  cleanup() {
    find "$dry_root" -depth -delete 2>/dev/null || true
  }
  trap cleanup EXIT INT TERM

  git_sha=$(git -C "$repo_root" rev-parse --verify HEAD)
  zero_digest=0000000000000000000000000000000000000000000000000000000000000000
  candidate_manifest="$dry_root/candidate-manifest.json"

  jq -n \
    --arg git_sha "$git_sha" \
    --arg digest "sha256:$zero_digest" \
    --arg sha256 "$zero_digest" '
    {
      schema: "openagents.staging-candidate.v1",
      git_sha: $git_sha,
      branch: "main",
      target: {environment: "staging", project: "openagents-staging-dry-run", region: "us-central1"},
      images: {application: {
        reference: ("us-central1-docker.pkg.dev/openagents-staging-dry-run/openagents/openagents@" + $digest),
        manifest_digest: $digest
      }},
      release: {version: "dry-run", sha256: $sha256}
    }
  ' >"$candidate_manifest"

  write_report "$candidate_manifest" "$zero_digest" "$zero_digest" dry-run true "$output"
  chmod 600 "$output"
  exit 0
fi

[ "$#" -eq 3 ] || usage
candidate_dir=$1
gate14_report=$2
run_id=$3

case "$run_id" in
  "" | *[!a-z0-9-]* | -* | *- | *--*)
    echo "RUN_ID must use lowercase letters, digits, and single interior hyphens" >&2
    exit 1
    ;;
esac

if [ "${#run_id}" -gt 63 ]; then
  echo "RUN_ID must contain at most 63 characters" >&2
  exit 1
fi

candidate_manifest="$candidate_dir/candidate-manifest.json"
candidate_checksum="$candidate_dir/candidate-manifest.sha256"

if [ ! -f "$candidate_manifest" ] || [ ! -f "$candidate_checksum" ]; then
  echo "candidate directory must contain the manifest and its checksum" >&2
  exit 1
fi

(cd "$candidate_dir" && sha256sum --check --strict candidate-manifest.sha256 >/dev/null)
gate14_dir=$(CDPATH= cd -- "$(dirname -- "$gate14_report")" && pwd)

if [ ! -f "$gate14_dir/report.sha256" ]; then
  echo "Gate 14 report checksum is missing" >&2
  exit 1
fi

(cd "$gate14_dir" && sha256sum --check --strict report.sha256 >/dev/null)
"$script_dir/validate-report.sh" --regression "$gate14_report" >/dev/null

candidate_sha=$(jq -r '.git_sha' "$candidate_manifest")
gate14_candidate_sha=$(jq -r '.candidate.git_sha' "$gate14_report")
candidate_image_digest=$(jq -r '.images.application.manifest_digest' "$candidate_manifest")
gate14_image_digest=$(jq -r '.candidate.application_manifest_digest' "$gate14_report")
candidate_release_sha256=$(jq -r '.release.sha256' "$candidate_manifest")
gate14_release_sha256=$(jq -r '.candidate.release_sha256' "$gate14_report")

if [ "$candidate_sha" != "$gate14_candidate_sha" ] ||
   [ "$candidate_image_digest" != "$gate14_image_digest" ] ||
   [ "$candidate_release_sha256" != "$gate14_release_sha256" ]; then
  echo "Gate 14 report does not identify the selected candidate" >&2
  exit 1
fi

jq -e '
  . as $manifest |
  .schema == "openagents.staging-candidate.v1" and
  (.git_sha | test("^[0-9a-f]{40}$")) and
  .branch == "main" and
  .target.environment == "staging" and
  (.target.project | test("stag"; "i")) and
  (.images.application.manifest_digest | test("^sha256:[0-9a-f]{64}$")) and
  (.images.application.reference | endswith("@" + $manifest.images.application.manifest_digest)) and
  (.release.sha256 | test("^[0-9a-f]{64}$"))
' "$candidate_manifest" >/dev/null || {
  echo "candidate manifest does not satisfy the resilience report contract" >&2
  exit 1
}

candidate_manifest_sha256=$(sha256sum "$candidate_manifest" | cut -d ' ' -f 1)
gate14_sha256=$(sha256sum "$gate14_report" | cut -d ' ' -f 1)
report_root="$repo_root/.git/openagents/staging-resilience/$candidate_sha/$run_id"
report_parent=$(dirname -- "$report_root")
report_temp=

if [ -e "$report_root" ]; then
  echo "resilience report already exists for this candidate and run ID" >&2
  exit 1
fi

mkdir -p "$report_parent"
report_temp=$(mktemp -d "$report_parent/.report.$run_id.XXXXXX")
cleanup() {
  if [ -n "$report_temp" ] && [ -d "$report_temp" ]; then
    find "$report_temp" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

write_report \
  "$candidate_manifest" \
  "$candidate_manifest_sha256" \
  "$gate14_sha256" \
  "$run_id" \
  false \
  "$report_temp/report.json"

report_sha256=$(sha256sum "$report_temp/report.json" | cut -d ' ' -f 1)
printf '%s  report.json\n' "$report_sha256" >"$report_temp/report.sha256"
mv "$report_temp" "$report_root"
report_temp=

echo "Created staging resilience report for $candidate_sha"
echo "Report: .git/openagents/staging-resilience/$candidate_sha/$run_id/report.json"
