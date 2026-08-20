#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/common.sh"

cd "$repo_root"

artifact_root=$(proof_root)
build_root=$(mktemp -d /tmp/openagents-relup-build.XXXXXX)
publish_root="$artifact_root.tmp.$$"
assets_digested=0

cleanup() {
  if [ "$assets_digested" = "1" ]; then
    (cd "$repo_root" && MIX_ENV=prod mix phx.digest.clean --all >/dev/null 2>&1) || true
  fi

  if [ -d "$build_root" ]; then
    find "$build_root" -depth -delete
  fi

  if [ -d "$publish_root" ]; then
    find "$publish_root" -depth -delete
  fi
}

trap cleanup EXIT INT TERM

mkdir -p "$publish_root"

echo "Building production assets"
assets_digested=1
MIX_ENV=prod mix assets.deploy

echo "Building explicit 0.1.0 release"
env -u RELUP_FROM -u RELUP_TO -u OPENAGENTS_RELUP_PATH \
  MIX_ENV=prod \
  OPENAGENTS_RELEASE_PATH="$build_root/release-0.1.0" \
  OPENAGENTS_RELEASE_VSN="0.1.0" \
  OPENAGENTS_RELUP_STATE_VERSION="1" \
  mix do compile --force --warnings-as-errors + release --overwrite

echo "Building explicit 0.2.0 release resource"
env -u OPENAGENTS_RELUP_PATH \
  MIX_ENV=prod \
  OPENAGENTS_RELEASE_PATH="$build_root/release-0.2.0" \
  OPENAGENTS_RELEASE_VSN="0.2.0" \
  OPENAGENTS_RELUP_STATE_VERSION="2" \
  RELUP_FROM="0.1.0" \
  RELUP_TO="0.2.0" \
  mix do compile --force --warnings-as-errors + release --overwrite

echo "Generating forward and reverse relup"
MIX_ENV=prod mix openagents.relup \
  --target "$build_root/release-0.2.0/releases/0.2.0/openagents" \
  --from "$build_root/release-0.1.0/releases/0.1.0/openagents" \
  --outdir "$build_root"

echo "Reassembling 0.2.0 with the generated relup"
env \
  MIX_ENV=prod \
  OPENAGENTS_RELEASE_PATH="$build_root/release-0.2.0" \
  OPENAGENTS_RELEASE_VSN="0.2.0" \
  OPENAGENTS_RELUP_PATH="$build_root/relup" \
  OPENAGENTS_RELUP_STATE_VERSION="2" \
  RELUP_FROM="0.1.0" \
  RELUP_TO="0.2.0" \
  mix release --overwrite

cp "$build_root/release-0.1.0/openagents-0.1.0.tar.gz" "$publish_root/openagents-0.1.0.tar.gz"
cp "$build_root/release-0.2.0/openagents-0.2.0.tar.gz" "$publish_root/openagents-0.2.0.tar.gz"
cp "$build_root/relup" "$publish_root/relup"

tar -tzf "$publish_root/openagents-0.2.0.tar.gz" | grep -Fxq 'releases/0.2.0/relup'

RELUP_FILE="$publish_root/relup" elixir -e '
  {:ok, [relup]} = :file.consult(String.to_charlist(System.fetch_env!("RELUP_FILE")))
  {~c"0.2.0", [{~c"0.1.0", _, _}], [{~c"0.1.0", _, _}]} = relup
'

v1_digest=$(sha256sum "$publish_root/openagents-0.1.0.tar.gz" | cut -d ' ' -f 1)
v2_digest=$(sha256sum "$publish_root/openagents-0.2.0.tar.gz" | cut -d ' ' -f 1)
relup_digest=$(sha256sum "$publish_root/relup" | cut -d ' ' -f 1)
git_sha=$(git rev-parse --verify HEAD)

cat >"$publish_root/proof.json" <<EOF
{
  "schema": "openagents.relup-build-proof.v1",
  "git_sha": "$git_sha",
  "from_version": "0.1.0",
  "to_version": "0.2.0",
  "forward": true,
  "reverse": true,
  "release_0_1_0_digest": "$v1_digest",
  "release_0_2_0_digest": "$v2_digest",
  "relup_digest": "$relup_digest"
}
EOF

mkdir -p "$(dirname -- "$artifact_root")"

if [ -d "$artifact_root" ]; then
  find "$artifact_root" -depth -delete
fi

mv "$publish_root" "$artifact_root"

echo "Relup build proof passed"
echo "Artifacts: $artifact_root"
