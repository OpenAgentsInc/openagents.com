#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
source "${repo_root}/ops/scv/images/versions.env"

image=${SCV_IMAGE:-openagents/scv-opencode-core:local}
platform=${SCV_IMAGE_PLATFORM:-}
git_sha=${SCV_BUILD_REVISION:-$(git -C "${repo_root}" rev-parse HEAD)}
source_date_epoch=$(git -C "${repo_root}" show -s --format=%ct "${git_sha}")

build_image() {
  docker build "$@" \
  --file "${repo_root}/ops/scv/images/opencode-core/Dockerfile" \
  --tag "${image}" \
  --build-arg "RUNTIME_IMAGE=${SCV_RUNTIME_IMAGE}" \
  --build-arg "ELIXIR_IMAGE=${SCV_ELIXIR_IMAGE}" \
  --build-arg "DEBIAN_SNAPSHOT=${SCV_DEBIAN_SNAPSHOT}" \
  --build-arg "HEX_VERSION=${SCV_HEX_VERSION}" \
  --build-arg "REBAR3_VERSION=${SCV_REBAR3_VERSION}" \
  --build-arg "REBAR3_SHA512=${SCV_REBAR3_SHA512}" \
  --build-arg "NODE_VERSION=${SCV_NODE_VERSION}" \
  --build-arg "BUN_VERSION=${SCV_BUN_VERSION}" \
  --build-arg "OPENCODE_VERSION=${SCV_OPENCODE_VERSION}" \
  --build-arg "OPENAGENTS_BUILD_REVISION=${git_sha}" \
  --build-arg "SOURCE_DATE_EPOCH=${source_date_epoch}" \
  --label "com.openagents.scv.image=opencode-core" \
  --label "com.openagents.scv.opencode.version=${SCV_OPENCODE_VERSION}" \
  --label "org.opencontainers.image.revision=${git_sha}" \
  "${repo_root}"
}

if [[ -n "${platform}" ]]; then
  build_image --platform "${platform}"
else
  build_image
fi

docker image inspect "${image}" --format '{{json .RepoDigests}} {{.Id}}'
