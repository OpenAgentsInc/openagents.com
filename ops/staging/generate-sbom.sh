#!/usr/bin/env bash
set -euo pipefail

readonly SYFT_IMAGE="anchore/syft@sha256:678bfa565b60f747aac0f8e964fe5588a24445b8d0a480e91f6efd70020dfbb0"

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <image-reference> <output.cdx.json>" >&2
  exit 64
fi

readonly image_reference="$1"
readonly output_path="$2"
readonly output_directory="$(dirname -- "$output_path")"

mkdir -p -- "$output_directory"

readonly temporary_sbom="$(mktemp "${output_path}.tmp.XXXXXX")"
readonly temporary_receipt="$(mktemp "${output_path}.receipt.tmp.XXXXXX")"

cleanup() {
  unlink "$temporary_sbom" 2>/dev/null || true
  unlink "$temporary_receipt" 2>/dev/null || true
}
trap cleanup EXIT

readonly image_digest="$(
  docker image inspect "$image_reference" \
    --format '{{index .RepoDigests 0}}' 2>/dev/null
)"

if [[ -z "$image_digest" || "$image_digest" == "<no value>" ]]; then
  echo "image must be present locally with a resolved repository digest: $image_reference" >&2
  exit 65
fi

docker run --rm \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  "$SYFT_IMAGE" \
  "docker:$image_digest" \
  --quiet \
  --output cyclonedx-json >"$temporary_sbom"

jq -e '
  .bomFormat == "CycloneDX" and
  (.specVersion | type == "string") and
  (.components | type == "array" and length > 0)
' "$temporary_sbom" >/dev/null

readonly source_commit="$(git rev-parse HEAD)"
readonly sbom_sha256="$(sha256sum "$temporary_sbom" | cut -d ' ' -f 1)"

{
  echo "source_commit=$source_commit"
  echo "image_digest=$image_digest"
  echo "syft_image=$SYFT_IMAGE"
  echo "format=cyclonedx-json"
  echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "sbom_sha256=$sbom_sha256"
} >"$temporary_receipt"

mv -- "$temporary_sbom" "$output_path"
mv -- "$temporary_receipt" "${output_path}.receipt"
trap - EXIT

echo "wrote $output_path"
echo "wrote ${output_path}.receipt"
