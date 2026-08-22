#!/bin/sh
# Package one two-way relup transition: two production release tarballs plus
# the generated relup, digest-addressed and ready for RelupDeployment.
#
# Usage:
#   ops/forge/package-relup.sh --from-version 0.2.0 --to-version 0.3.0 \
#     [--from-rev <sha|ref>] [--to-rev <sha|ref>] \
#     [--from-state 2] [--to-state 2] [--out-dir DIR]
#
# Builds each revision in an isolated temporary worktree, so the working
# checkout is untouched. The steps mirror ops/relup-proof/run.sh, which is the
# proven recipe; this script parameterizes it for real version pairs. Whether
# a specific pair installs is still decided by the packaged appup and
# `release_handler` on the target nodes at check_install time.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

usage() {
  echo "usage: $0 --from-version V --to-version V [--from-rev REF] [--to-rev REF] [--from-state N] [--to-state N] [--out-dir DIR]" >&2
  exit 2
}

from_version=""
to_version=""
from_rev="HEAD"
to_rev="HEAD"
from_state="2"
to_state="2"
out_dir=""

while [ $# -gt 0 ]; do
  case "$1" in
    --from-version) from_version="$2"; shift 2 ;;
    --to-version) to_version="$2"; shift 2 ;;
    --from-rev) from_rev="$2"; shift 2 ;;
    --to-rev) to_rev="$2"; shift 2 ;;
    --from-state) from_state="$2"; shift 2 ;;
    --to-state) to_state="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$from_version" ] || usage
[ -n "$to_version" ] || usage

version_ok() {
  echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'
}

state_ok() {
  echo "$1" | grep -Eq '^[12]$'
}

version_ok "$from_version" || { echo "from-version must be X.Y.Z" >&2; exit 2; }
version_ok "$to_version" || { echo "to-version must be X.Y.Z" >&2; exit 2; }
state_ok "$from_state" || { echo "from-state must be 1 or 2" >&2; exit 2; }
state_ok "$to_state" || { echo "to-state must be 1 or 2" >&2; exit 2; }

if [ "$from_version" = "$to_version" ]; then
  echo "from-version and to-version must differ" >&2
  exit 2
fi

if [ "$to_state" -lt "$from_state" ]; then
  echo "to-state must not regress below from-state" >&2
  exit 2
fi

from_sha=$(git -C "$repo_root" rev-parse --verify "${from_rev}^{commit}")
to_sha=$(git -C "$repo_root" rev-parse --verify "${to_rev}^{commit}")
target_system=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(system_architecture)]), halt().' 2>/dev/null)

[ -n "$target_system" ] || { echo "could not determine the release target system" >&2; exit 1; }

build_root=$(mktemp -d "${TMPDIR:-/tmp}/openagents-relup-package.XXXXXX")
assets_digested=0

cleanup() {
  git -C "$repo_root" worktree remove --force "$build_root/from" >/dev/null 2>&1 || true
  git -C "$repo_root" worktree remove --force "$build_root/to" >/dev/null 2>&1 || true

  if [ "$assets_digested" = "1" ]; then
    (git -C "$repo_root" worktree list --porcelain >/dev/null 2>&1) || true
  fi

  rm -rf "$build_root"
}

trap cleanup EXIT INT TERM

git -C "$repo_root" worktree add --detach "$build_root/from" "$from_sha" >/dev/null
git -C "$repo_root" worktree add --detach "$build_root/to" "$to_sha" >/dev/null

echo "Fetching dependencies (from tree)"
(cd "$build_root/from" && MIX_ENV=prod mix deps.get >/dev/null)
(cd "$build_root/from" && npm install --prefix assets --no-audit --no-fund >/dev/null 2>&1)

echo "Fetching dependencies (to tree)"
(cd "$build_root/to" && MIX_ENV=prod mix deps.get >/dev/null)
(cd "$build_root/to" && npm install --prefix assets --no-audit --no-fund >/dev/null 2>&1)

echo "Building production assets (from tree)"
(cd "$build_root/from" && MIX_ENV=prod mix assets.deploy)
assets_digested=1

echo "Building production assets (to tree)"
(cd "$build_root/to" && MIX_ENV=prod mix assets.deploy)

echo "Building $from_version release"
env -u RELUP_FROM -u RELUP_TO -u OPENAGENTS_RELUP_PATH \
  MIX_ENV=prod \
  OPENAGENTS_RELEASE_PATH="$build_root/from/release" \
  OPENAGENTS_RELEASE_VSN="$from_version" \
  OPENAGENTS_RELUP_STATE_VERSION="$from_state" \
  OPENAGENTS_BUILD_REVISION="$from_sha" \
  sh -c 'cd "$1" && mix do compile --force --warnings-as-errors + release --overwrite' sh "$build_root/from"

# The appup derives its instruction list from these two module sets, so every
# module that differs between the revisions is covered. Both sides must be
# _build ebin directories: protocol consolidation happens later, in `mix
# release`, and comparing a release ebin against a _build ebin would report
# modules as added or deleted that neither revision touched.
from_ebin="$build_root/from/_build/prod/lib/openagents/ebin"
[ -d "$from_ebin" ] || { echo "missing from-build ebin: $from_ebin" >&2; exit 1; }

echo "Building $to_version release resource"
env -u OPENAGENTS_RELUP_PATH \
  MIX_ENV=prod \
  OPENAGENTS_RELEASE_PATH="$build_root/to/release" \
  OPENAGENTS_RELEASE_VSN="$to_version" \
  OPENAGENTS_RELUP_STATE_VERSION="$to_state" \
  OPENAGENTS_BUILD_REVISION="$to_sha" \
  RELUP_FROM="$from_version" \
  RELUP_TO="$to_version" \
  RELUP_FROM_EBIN="$from_ebin" \
  RELUP_FROM_STATE="$from_state" \
  RELUP_TO_STATE="$to_state" \
  sh -c 'cd "$1" && mix do compile --force --warnings-as-errors + release --overwrite' sh "$build_root/to"

to_ebin="$build_root/to/_build/prod/lib/openagents/ebin"
[ -d "$to_ebin" ] || { echo "missing to-build ebin: $to_ebin" >&2; exit 1; }

echo "Generating the two-way relup"
(cd "$build_root/to" && MIX_ENV=prod mix openagents.relup \
  --target "$build_root/to/release/releases/$to_version/openagents" \
  --from "$build_root/from/release/releases/$from_version/openagents" \
  --outdir "$build_root" \
  --from-ebin "$from_ebin" \
  --to-ebin "$to_ebin" \
  --from-state "$from_state" \
  --to-state "$to_state")

echo "Reassembling $to_version with the embedded relup"
env \
  MIX_ENV=prod \
  OPENAGENTS_RELEASE_PATH="$build_root/to/release" \
  OPENAGENTS_RELEASE_VSN="$to_version" \
  OPENAGENTS_RELUP_PATH="$build_root/relup" \
  OPENAGENTS_RELUP_STATE_VERSION="$to_state" \
  OPENAGENTS_BUILD_REVISION="$to_sha" \
  RELUP_FROM="$from_version" \
  RELUP_TO="$to_version" \
  RELUP_FROM_EBIN="$from_ebin" \
  RELUP_FROM_STATE="$from_state" \
  RELUP_TO_STATE="$to_state" \
  sh -c 'cd "$1" && mix release --overwrite' sh "$build_root/to"

tar -tzf "$build_root/to/release/openagents-$to_version.tar.gz" |
  grep -Fxq "releases/$to_version/relup"

publish_root="$out_dir"
if [ -z "$publish_root" ]; then
  publish_root="$repo_root/artifacts/relup/$from_version-to-$to_version"
fi

from_digest=$(sha256sum "$build_root/from/release/openagents-$from_version.tar.gz" | cut -d ' ' -f 1)
to_digest=$(sha256sum "$build_root/to/release/openagents-$to_version.tar.gz" | cut -d ' ' -f 1)
relup_digest=$(sha256sum "$build_root/relup" | cut -d ' ' -f 1)

mkdir -p "$publish_root"
cp "$build_root/from/release/openagents-$from_version.tar.gz" "$publish_root/"
cp "$build_root/to/release/openagents-$to_version.tar.gz" "$publish_root/"
cp "$build_root/relup" "$publish_root/"

cat >"$publish_root/package.json" <<EOF
{
  "schema": "openagents.relup-package.v1",
  "release_name": "openagents",
  "from_revision": "$from_sha",
  "to_revision": "$to_sha",
  "from_version": "$from_version",
  "to_version": "$to_version",
  "from_state_version": $from_state,
  "to_state_version": $to_state,
  "target_system": "$target_system",
  "from_artifact_digest": "$from_digest",
  "to_artifact_digest": "$to_digest",
  "relup_digest": "$relup_digest"
}
EOF

echo "Relup package ready: $publish_root"
echo "  openagents-$from_version.tar.gz  sha256:$from_digest"
echo "  openagents-$to_version.tar.gz    sha256:$to_digest"
echo "  relup                            sha256:$relup_digest"
