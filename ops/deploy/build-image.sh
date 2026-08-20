#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]; then
  echo "image build requires a clean worktree" >&2
  exit 1
fi

git_sha=$(git -C "$repo_root" rev-parse --verify HEAD)
tag=${1:-"openagents:$git_sha"}
image_root="$repo_root/.git/openagents/images"
result_path="$image_root/$git_sha.json"
iid_file=$(mktemp /tmp/openagents-image-iid.XXXXXX)

cleanup() {
  unlink "$iid_file" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

"$repo_root/ops/ci/gate.sh" --verify

docker build \
  --iidfile "$iid_file" \
  --label "org.opencontainers.image.revision=$git_sha" \
  --tag "$tag" \
  --target final \
  "$repo_root"

image_digest=$(tr -d '\n' <"$iid_file")

case "$image_digest" in
  sha256:????????????????????????????????????????????????????????????????) ;;
  *)
    echo "container builder did not return an immutable SHA-256 image ID" >&2
    exit 1
    ;;
esac

mkdir -p "$image_root"
umask 077

cat >"$result_path" <<EOF
{
  "schema": "openagents.local-image.v1",
  "git_sha": "$git_sha",
  "image_digest": "$image_digest",
  "tag": "$tag"
}
EOF

echo "Built $tag as $image_digest"
echo "Receipt: .git/openagents/images/$git_sha.json"
