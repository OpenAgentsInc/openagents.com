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

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  echo "refusing to generate release evidence from a dirty worktree" >&2
  exit 66
fi

readonly source_commit="$(git rev-parse HEAD)"

readonly image_digest="$(
  docker image inspect "$image_reference" \
    --format '{{index .RepoDigests 0}}' 2>/dev/null
)"

if [[ -z "$image_digest" || "$image_digest" == "<no value>" ]]; then
  echo "image must be present locally with a resolved repository digest: $image_reference" >&2
  exit 65
fi

readonly image_revision="$(
  docker image inspect "$image_reference" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null
)"

if [[ "$image_revision" != "$source_commit" ]]; then
  echo "image revision does not match HEAD: image=$image_revision head=$source_commit" >&2
  exit 67
fi

mkdir -p -- "$output_directory"

readonly temporary_sbom="$(mktemp "${output_path}.tmp.XXXXXX")"
readonly temporary_receipt="$(mktemp "${output_path}.receipt.tmp.XXXXXX")"
readonly scan_directory="$(mktemp -d "${TMPDIR:-/tmp}/openagents-sbom.XXXXXX")"
container_id=""

cleanup() {
  if [[ -n "$container_id" ]]; then
    docker rm "$container_id" >/dev/null 2>&1 || true
  fi

  unlink "$temporary_sbom" 2>/dev/null || true
  unlink "$temporary_receipt" 2>/dev/null || true
  find "$scan_directory" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

readonly rootfs_archive="$scan_directory/rootfs.tar"
readonly rootfs_directory="$scan_directory/rootfs"

mkdir "$rootfs_directory"
container_id="$(docker create "$image_digest")"
docker export "$container_id" --output "$rootfs_archive"
docker rm "$container_id" >/dev/null
container_id=""

tar --extract \
  --file "$rootfs_archive" \
  --directory "$rootfs_directory" \
  --no-same-owner
unlink "$rootfs_archive"

docker run --rm \
  --volume "$rootfs_directory:/scan:ro" \
  "$SYFT_IMAGE" \
  dir:/scan \
  --quiet \
  --select-catalogers '+erlang-otp-application-cataloger' \
  --source-name "$image_digest" \
  --source-version "$source_commit" \
  --output cyclonedx-json >"$temporary_sbom"

jq -e '
  .bomFormat == "CycloneDX" and
  (.specVersion | type == "string") and
  (.components | type == "array" and length > 0) and
  any(.components[]; (.purl // "") | startswith("pkg:deb/")) and
  any(.components[]; (.purl // "") | startswith("pkg:otp/"))
' "$temporary_sbom" >/dev/null

readonly sbom_sha256="$(sha256sum "$temporary_sbom" | cut -d ' ' -f 1)"

{
  echo "source_commit=$source_commit"
  echo "image_digest=$image_digest"
  echo "image_revision=$image_revision"
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
