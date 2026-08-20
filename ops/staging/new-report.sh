#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
matrix="$script_dir/regression-matrix.json"
mode=${1:-}
umask 077

usage() {
  echo "usage: ops/staging/new-report.sh CANDIDATE_DIRECTORY RUN_ID" >&2
  echo "       ops/staging/new-report.sh --dry-run OUTPUT" >&2
  exit 64
}

for command_name in git jq sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required to create a staging report" >&2
    exit 1
  fi
done

generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

write_report() {
  candidate_manifest=$1
  candidate_manifest_sha256=$2
  run_id=$3
  synthetic=$4
  output=$5

  jq -n \
    --slurpfile matrix "$matrix" \
    --slurpfile candidate "$candidate_manifest" \
    --arg run_id "$run_id" \
    --arg created_at "$generated_at" \
    --arg candidate_manifest_sha256 "$candidate_manifest_sha256" \
    --argjson synthetic "$synthetic" '
    ($matrix[0]) as $matrix |
    ($candidate[0]) as $candidate |
    {
      schema: "openagents.staging-report.v1",
      matrix_revision: $matrix.revision,
      state: "draft",
      synthetic: $synthetic,
      run_id: $run_id,
      created_at: $created_at,
      completed_at: null,
      target: {
        environment: "staging",
        base_url: "https://staging.openagents.com",
        project: $candidate.target.project,
        region: $candidate.target.region
      },
      candidate: {
        git_sha: $candidate.git_sha,
        branch: $candidate.branch,
        candidate_manifest_sha256: $candidate_manifest_sha256,
        application_image: $candidate.images.application.reference,
        application_manifest_digest: $candidate.images.application.manifest_digest,
        builder_image: $candidate.images.builder.reference,
        builder_manifest_digest: $candidate.images.builder.manifest_digest,
        release_version: $candidate.release.version,
        release_sha256: $candidate.release.sha256,
        sbom_sha256: $candidate.sbom.sha256,
        release_gate_sha256: $candidate.receipts.release_gate_sha256
      },
      staging_evidence: {
        migration: {
          classification: null,
          snapshot_receipt: null,
          rehearsal_receipt: null,
          migration_versions_receipt: null,
          rollback_compatibility_receipt: null
        },
        configuration_readiness_receipt: null,
        local_gate: {
          default_test_count: null,
          cluster_test_count: null,
          javascript_test_count: null,
          coverage_summary_receipt: null
        },
        deployment: {
          web_revision: null,
          web_image_digest: null,
          distributed_node_release_receipt: null
        },
        forge: {
          build_receipt: null,
          deployment_receipt: null,
          rollback_receipt: null,
          relup_receipt: null,
          rolling_replacement_receipt: null
        },
        sanitized_artifacts: [],
        failure_injection_timeline: [],
        soak_receipt: null,
        known_issues: []
      },
      results: [
        $matrix.groups[] as $group |
        $group.cases[] |
        {
          id: .id,
          group: $group.id,
          title: .title,
          execution: .execution,
          status: "pending",
          reason: null,
          attempts: [],
          evidence: []
        }
      ]
    }
  ' >"$output"
}

if [ "$mode" = "--dry-run" ]; then
  [ "$#" -eq 2 ] || usage
  output=$2

  if [ -e "$output" ]; then
    echo "dry-run report output already exists" >&2
    exit 1
  fi

  dry_root=$(mktemp -d /tmp/openagents-staging-report-dry-run.XXXXXX)
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
      images: {
        application: {
          reference: ("us-central1-docker.pkg.dev/openagents-staging-dry-run/openagents-staging/openagents@" + $digest),
          manifest_digest: $digest
        },
        builder: {
          reference: ("us-central1-docker.pkg.dev/openagents-staging-dry-run/openagents-staging/openagents-builder@" + $digest),
          manifest_digest: $digest
        }
      },
      release: {version: "dry-run", sha256: $sha256},
      sbom: {sha256: $sha256},
      receipts: {release_gate_sha256: $sha256}
    }
  ' >"$candidate_manifest"

  write_report "$candidate_manifest" "$zero_digest" dry-run true "$output"
  chmod 600 "$output"
  exit 0
fi

[ "$#" -eq 2 ] || usage
candidate_dir=$1
run_id=$2

case "$run_id" in
  [a-z0-9]*[a-z0-9]) ;;
  [a-z0-9]) ;;
  *) echo "RUN_ID must use lowercase letters, digits, and interior hyphens" >&2; exit 1 ;;
esac

case "$run_id" in
  *[!a-z0-9-]* | *--* | *- | -* )
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

jq -e '
  . as $manifest |
  .schema == "openagents.staging-candidate.v1" and
  (.git_sha | test("^[0-9a-f]{40}$")) and
  .branch == "main" and
  .target.environment == "staging" and
  (.target.project | test("stag"; "i")) and
  (.target.region | type == "string" and length > 0) and
  (.images.application.manifest_digest | test("^sha256:[0-9a-f]{64}$")) and
  (.images.builder.manifest_digest | test("^sha256:[0-9a-f]{64}$")) and
  (.images.application.reference | endswith("@" + $manifest.images.application.manifest_digest)) and
  (.images.builder.reference | endswith("@" + $manifest.images.builder.manifest_digest)) and
  (.release.sha256 | test("^[0-9a-f]{64}$")) and
  (.sbom.sha256 | test("^[0-9a-f]{64}$")) and
  (.receipts.release_gate_sha256 | test("^[0-9a-f]{64}$"))
' "$candidate_manifest" >/dev/null || {
  echo "candidate manifest does not satisfy the staging report contract" >&2
  exit 1
}

git_sha=$(jq -r '.git_sha' "$candidate_manifest")
candidate_manifest_sha256=$(sha256sum "$candidate_manifest" | cut -d ' ' -f 1)
evidence_root="$repo_root/.git/openagents/staging-reports/$git_sha"
report_root="$evidence_root/$run_id"
report_temp=

if [ -e "$report_root" ]; then
  echo "staging report already exists for this candidate and run ID" >&2
  exit 1
fi

umask 077
mkdir -p "$evidence_root"
report_temp=$(mktemp -d "$evidence_root/.report.$run_id.XXXXXX")

cleanup() {
  if [ -n "$report_temp" ] && [ -d "$report_temp" ]; then
    find "$report_temp" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

write_report \
  "$candidate_manifest" \
  "$candidate_manifest_sha256" \
  "$run_id" \
  false \
  "$report_temp/report.json"

report_sha256=$(sha256sum "$report_temp/report.json" | cut -d ' ' -f 1)
printf '%s  report.json\n' "$report_sha256" >"$report_temp/report.sha256"
mv "$report_temp" "$report_root"
report_temp=

echo "Created staging report for $git_sha"
echo "Report: .git/openagents/staging-reports/$git_sha/$run_id/report.json"
