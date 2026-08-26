#!/bin/sh
# Build the production image on Cloud Build, for a machine that cannot build it
# locally.
#
# `ops/deploy/build-image.sh` builds and then *runs* the amd64 image to check
# that its packaged revision equals the Git SHA. On an Apple Silicon machine
# that run happens under amd64 emulation, and the Erlang VM cannot start there:
# it dies at kernel start with
#
#     failed_to_start_child,user,nouser
#
# reproducible on the bare `hexpm/elixir` base image, and unaffected by
# `-noinput` or `TERM=dumb`. So the local path cannot produce a production image
# on such a machine at all. Cloud Build workers are native amd64, so the same
# build and the same check run for real rather than emulated.
#
# The revision check is kept rather than dropped to get past the wall. An image
# whose packaged BuildInfo does not equal the exact Git SHA must not reach the
# registry, because the release path identifies what the fleet runs by that SHA.
#
# Usage: ops/deploy/build-image-cloud.sh <git-sha>
set -eu

sha=${1:-}
[ -n "$sha" ] || { echo "usage: $0 <git-sha>" >&2; exit 2; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

project=${OPENAGENTS_BUILD_PROJECT:-openagentsgemini}
service_account=${OPENAGENTS_BUILD_SERVICE_ACCOUNT:-projects/openagentsgemini/serviceAccounts/oa-mvp-automation@openagentsgemini.iam.gserviceaccount.com}
image=${OPENAGENTS_IMAGE_REPOSITORY:-us-central1-docker.pkg.dev/openagents-staging-20260820/openagents-staging/openagents}

# The checks below exist because skipping them cost a real deploy.
#
# The first attempt at this ran `gcloud builds submit .` after a `cd` that had
# silently failed, so it uploaded a *different* checkout — one commit behind,
# with untracked files — and tagged the result with the SHA that was asked for.
# The packaged-revision check did not catch it: the revision is passed in as a
# build argument, so it reported the SHA it was told regardless of the source.
# The registry has tag immutability, so that tag could not be corrected and the
# SHA is unusable forever.
#
# A build argument can only ever confirm what it was handed. What the source
# actually is has to be checked here, before a build is spent on it.

head=$(git -C "$repo_root" rev-parse HEAD)
if [ "$head" != "$sha" ]; then
    echo "refusing: $repo_root is at $head, not $sha" >&2
    echo "  Build from a worktree checked out at the exact revision:" >&2
    echo "    git worktree add --detach <path> $sha" >&2
    exit 1
fi

dirty=$(git -C "$repo_root" status --porcelain --untracked-files=all |
    grep -v '^?? \.gcloudignore$' || true)
if [ -n "$dirty" ]; then
    echo "refusing: the worktree is not clean, so the image would not be $sha" >&2
    echo "$dirty" >&2
    exit 1
fi

# A tag in this repository cannot be moved, so a wrong image is permanent.
# Refuse before building rather than discovering it at push time.
existing=$(gcloud artifacts docker images describe "$image:$sha" \
    --format='value(image_summary.digest)' 2>/dev/null || true)
if [ -n "$existing" ]; then
    echo "refusing: $image:$sha already exists ($existing)" >&2
    echo "  Tags here are immutable. If that image is wrong, it cannot be" >&2
    echo "  replaced -- land another commit and build that SHA instead." >&2
    exit 1
fi

release_version=$(tr -d '\n' <"$repo_root/VERSION")
source_date_epoch=$(git -C "$repo_root" show -s --format=%ct "$sha")

# Keep the upload to the sources the Dockerfile copies.
cat >"$repo_root/.gcloudignore" <<'IGNORE'
.git
.gcloudignore
deps
_build
node_modules
assets/node_modules
erl_crash.dump
IGNORE

config=$(mktemp /tmp/openagents-cloudbuild.XXXXXX.yaml)
trap 'rm -f "$config"' EXIT INT TERM

cat >"$config" <<'BUILD'
steps:
  - id: build
    name: gcr.io/cloud-builders/docker
    args:
      - build
      - --build-arg
      - OPENAGENTS_BUILD_REVISION=${_SHA}
      - --build-arg
      - OPENAGENTS_RELEASE_VSN=${_RELEASE_VSN}
      - --build-arg
      - SOURCE_DATE_EPOCH=${_SOURCE_DATE_EPOCH}
      - --label
      - org.opencontainers.image.revision=${_SHA}
      - --tag
      - ${_IMAGE}:${_SHA}
      - --target
      - final
      - .

  # The assertion ops/deploy/build-image.sh makes locally. The erl invocation
  # lives in a file so its quoting survives YAML and two shells.
  - id: verify-revision
    name: gcr.io/cloud-builders/docker
    entrypoint: bash
    args:
      - -c
      - |
        set -eu
        cat > /workspace/packaged-revision.sh <<'CHECK'
        release_version=$$(awk '{print $$2}' /app/releases/start_erl.data)
        exec /app/erts-*/bin/erl \
          -boot_var RELEASE_LIB /app/lib \
          -boot "/app/releases/$$release_version/start_clean" \
          -noshell \
          -pa /app/lib/openagents-*/ebin \
          -eval "io:put_chars('Elixir.OpenAgents.BuildInfo':revision()), halt()."
        CHECK
        packaged=$$(docker run --rm \
          -v /workspace:/workspace \
          --entrypoint /bin/sh \
          "${_IMAGE}:${_SHA}" /workspace/packaged-revision.sh | tail -n 1)
        if [ "$$packaged" != "${_SHA}" ]; then
          echo "packaged BuildInfo revision '$$packaged' does not match the Git SHA '${_SHA}'" >&2
          exit 1
        fi
        echo "packaged revision matches: $$packaged"

images:
  - ${_IMAGE}:${_SHA}

options:
  machineType: E2_HIGHCPU_8
  logging: CLOUD_LOGGING_ONLY

timeout: 3600s
BUILD

echo "==> building $sha on Cloud Build (project $project)"
gcloud builds submit "$repo_root" \
    --project "$project" \
    --service-account "$service_account" \
    --config "$config" \
    --substitutions "_SHA=$sha,_RELEASE_VSN=$release_version,_SOURCE_DATE_EPOCH=$source_date_epoch,_IMAGE=$image"

rm -f "$repo_root/.gcloudignore"
echo "Built and pushed $image:$sha"
