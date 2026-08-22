#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
git_common_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)

if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]; then
  echo "image build requires a clean worktree" >&2
  exit 1
fi

git_sha=$(git -C "$repo_root" rev-parse --verify HEAD)
source_date_epoch=$(git -C "$repo_root" show -s --format=%ct "$git_sha")
platform=${OPENAGENTS_IMAGE_PLATFORM:-linux/amd64}
tag=${1:-"openagents:$git_sha"}
image_root="$git_common_dir/openagents/images"
result_path="$image_root/$git_sha.json"
iid_file=$(mktemp /tmp/openagents-image-iid.XXXXXX)

cleanup() {
  unlink "$iid_file" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

if [ "$platform" != "linux/amd64" ]; then
  echo "OPENAGENTS_IMAGE_PLATFORM must be linux/amd64 for the staging fleet" >&2
  exit 1
fi

"$repo_root/ops/ci/gate.sh" --verify

docker build \
  --platform "$platform" \
  --build-arg "OPENAGENTS_BUILD_REVISION=$git_sha" \
  --build-arg "SOURCE_DATE_EPOCH=$source_date_epoch" \
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

embedded_revision=$(
  docker run --rm \
    --entrypoint /bin/sh \
    "$image_digest" \
    -c 'release_version=$(awk '\''{print $2}'\'' /app/releases/start_erl.data); /app/erts-*/bin/erl -boot_var RELEASE_LIB /app/lib -boot "/app/releases/$release_version/start_clean" -noshell -pa /app/lib/openagents-*/ebin -eval "io:put_chars('\''Elixir.OpenAgents.BuildInfo'\'':revision()), halt()."' \
    | tail -n 1
)

if [ "$embedded_revision" != "$git_sha" ]; then
  echo "packaged BuildInfo revision does not match the exact Git SHA" >&2
  exit 1
fi

mkdir -p "$image_root"
umask 077

cat >"$result_path" <<EOF
{
  "schema": "openagents.local-image.v1",
  "git_sha": "$git_sha",
  "image_digest": "$image_digest",
  "digest_scope": "local_config",
  "platform": "$platform",
  "source_date_epoch": $source_date_epoch,
  "tag": "$tag"
}
EOF

echo "Built $tag as $image_digest"
echo "Receipt: .git/openagents/images/$git_sha.json"
