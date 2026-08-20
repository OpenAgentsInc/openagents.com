#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
source "${repo_root}/ops/scv/images/versions.env"

project=${SCV_GCP_PROJECT:?Set SCV_GCP_PROJECT to the staging Google Cloud project}
region=${SCV_GCP_REGION:-us-central1}
build_service_account=${SCV_BUILD_SERVICE_ACCOUNT:-oa-cloud-image-builder@${project}.iam.gserviceaccount.com}
git_sha=${SCV_BUILD_REVISION:-$(git -C "${repo_root}" rev-parse HEAD)}
source_date_epoch=$(git -C "${repo_root}" show -s --format=%ct "${git_sha}")
image=${SCV_IMAGE:-${region}-docker.pkg.dev/${project}/openagents-scv-staging/opencode-core:${git_sha}}

if [[ -n "$(git -C "${repo_root}" status --porcelain)" ]]; then
  echo "The SCV Cloud Build context must match a clean Git commit." >&2
  exit 1
fi

substitutions=(
  "_IMAGE=${image}"
  "_RUNTIME_IMAGE=${SCV_RUNTIME_IMAGE}"
  "_ELIXIR_IMAGE=${SCV_ELIXIR_IMAGE}"
  "_DEBIAN_SNAPSHOT=${SCV_DEBIAN_SNAPSHOT}"
  "_HEX_VERSION=${SCV_HEX_VERSION}"
  "_REBAR3_VERSION=${SCV_REBAR3_VERSION}"
  "_REBAR3_SHA512=${SCV_REBAR3_SHA512}"
  "_NODE_VERSION=${SCV_NODE_VERSION}"
  "_BUN_VERSION=${SCV_BUN_VERSION}"
  "_OPENCODE_VERSION=${SCV_OPENCODE_VERSION}"
  "_BUILD_REVISION=${git_sha}"
  "_SOURCE_DATE_EPOCH=${source_date_epoch}"
)

substitution_csv=$(IFS=,; echo "${substitutions[*]}")

gcloud builds submit "${repo_root}" \
  --config="${repo_root}/ops/scv/images/cloudbuild-opencode-core.yaml" \
  --project="${project}" \
  --region="${region}" \
  --service-account="projects/${project}/serviceAccounts/${build_service_account}" \
  --substitutions="${substitution_csv}"
