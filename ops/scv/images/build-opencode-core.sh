#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
source "${repo_root}/ops/scv/images/versions.env"

image=${SCV_IMAGE:-openagents/scv-opencode-core:local}

docker build \
  --file "${repo_root}/ops/scv/images/opencode-core/Dockerfile" \
  --tag "${image}" \
  --build-arg "UBUNTU_IMAGE=${SCV_UBUNTU_IMAGE}" \
  --build-arg "NODE_VERSION=${SCV_NODE_VERSION}" \
  --build-arg "BUN_VERSION=${SCV_BUN_VERSION}" \
  --build-arg "OPENCODE_VERSION=${SCV_OPENCODE_VERSION}" \
  --label "com.openagents.scv.image=opencode-core" \
  --label "com.openagents.scv.opencode.version=${SCV_OPENCODE_VERSION}" \
  "${repo_root}"

docker image inspect "${image}" --format '{{json .RepoDigests}} {{.Id}}'
