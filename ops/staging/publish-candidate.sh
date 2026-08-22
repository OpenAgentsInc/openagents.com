#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

mode=${1:-check}
staging_project=${OPENAGENTS_STAGING_PROJECT_ID:-}
production_project=${OPENAGENTS_PRODUCTION_PROJECT_ID:-}
region=${OPENAGENTS_STAGING_REGION:-us-central1}
repository_id=openagents-staging
platform=linux/amd64

: "${staging_project:?OPENAGENTS_STAGING_PROJECT_ID is required}"
: "${production_project:?OPENAGENTS_PRODUCTION_PROJECT_ID is required}"

case "$mode" in
  check) ;;
  --publish) ;;
  *) echo "usage: ops/staging/publish-candidate.sh [check|--publish]" >&2; exit 64 ;;
esac

case "$staging_project" in
  *stag*) ;;
  *) echo "staging project ID must contain 'stag'" >&2; exit 1 ;;
esac

if [ "$staging_project" = "$production_project" ]; then
  echo "staging and production project IDs must differ" >&2
  exit 1
fi

for command_name in docker gcloud jq sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required" >&2
    exit 1
  fi
done

cd "$repo_root"

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  echo "candidate publication requires a clean worktree" >&2
  exit 1
fi

git_sha=$(git rev-parse --verify HEAD)
origin_main=$(git rev-parse --verify refs/remotes/origin/main)
source_date_epoch=$(git show -s --format=%ct "$git_sha")

if [ "$git_sha" != "$origin_main" ]; then
  echo "candidate must equal the locally fetched origin/main commit" >&2
  exit 1
fi

ops/ci/gate.sh --verify
gcloud auth print-access-token >/dev/null

repository_json=$(
  gcloud artifacts repositories describe "$repository_id" \
    --project="$staging_project" \
    --location="$region" \
    --format=json
)

echo "$repository_json" | jq -e '
  .format == "DOCKER" and
  .dockerConfig.immutableTags == true
' >/dev/null || {
  echo "staging Artifact Registry must be Docker format with immutable tags" >&2
  exit 1
}

if [ "$mode" = check ]; then
  echo "Candidate publication preflight passed for $git_sha"
  exit 0
fi

registry_host="${region}-docker.pkg.dev"
repository="${registry_host}/${staging_project}/${repository_id}"
application_repository="${repository}/openagents"
builder_repository="${repository}/openagents-builder"
application_tag="${application_repository}:${git_sha}"
builder_tag="${builder_repository}:${git_sha}"
git_common_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)
evidence_root="$git_common_dir/openagents/staging-candidates"
candidate_path="$evidence_root/$git_sha"
run_root=$(mktemp -d /tmp/openagents-staging-candidate.XXXXXX)
candidate_temp=
builder_container=

cleanup() {
  if [ -n "$builder_container" ]; then
    docker rm "$builder_container" >/dev/null 2>&1 || true
  fi

  if [ -n "$candidate_temp" ] && [ -d "$candidate_temp" ]; then
    find "$candidate_temp" -depth -delete 2>/dev/null || true
  fi

  find "$run_root" -depth -delete 2>/dev/null || true
}

trap cleanup EXIT INT TERM

if [ -e "$candidate_path" ]; then
  if jq -e --arg sha "$git_sha" '.git_sha == $sha' \
    "$candidate_path/candidate-manifest.json" >/dev/null 2>&1; then
    echo "Candidate evidence already exists for $git_sha"
    exit 0
  fi

  echo "candidate evidence path exists without a valid exact-SHA manifest" >&2
  exit 1
fi

umask 077
mkdir -p "$evidence_root"
candidate_temp=$(mktemp -d "$evidence_root/.candidate.$git_sha.XXXXXX")

gcloud auth configure-docker "$registry_host" --quiet >/dev/null

remote_digest() {
  image_tag=$1
  receipt_name=$2
  descriptor="$run_root/$receipt_name.descriptor.json"
  inspect_error="$run_root/$receipt_name.inspect-error"

  if docker buildx imagetools inspect "$image_tag" \
    --format '{{json .Manifest}}' >"$descriptor" 2>"$inspect_error"; then
    if jq -er '.digest | select(test("^sha256:[0-9a-f]{64}$"))' "$descriptor"; then
      return 0
    fi

    echo "registry returned an invalid manifest descriptor for $image_tag" >&2
    cat "$descriptor" >&2
    return 2
  fi

  if grep -Eiq 'not found|manifest unknown|does not exist' "$inspect_error"; then
    return 1
  fi

  cat "$inspect_error" >&2
  return 2
}

verify_platform() {
  image_reference=$1
  operating_system=$(docker image inspect "$image_reference" --format '{{.Os}}')
  architecture=$(docker image inspect "$image_reference" --format '{{.Architecture}}')

  if [ "$operating_system/$architecture" != "$platform" ]; then
    echo "$image_reference resolved to $operating_system/$architecture, expected $platform" >&2
    return 1
  fi

  return 0
}

if application_digest=$(remote_digest "$application_tag" application); then
  echo "Reusing immutable application tag for $git_sha"
else
  remote_status=$?
  if [ "$remote_status" -ne 1 ]; then
    exit "$remote_status"
  fi

  OPENAGENTS_IMAGE_PLATFORM="$platform" ops/deploy/build-image.sh "$application_tag"
  docker push "$application_tag" >/dev/null
  application_digest=$(remote_digest "$application_tag" application)
fi

if builder_digest=$(remote_digest "$builder_tag" builder); then
  echo "Reusing immutable builder tag for $git_sha"
else
  remote_status=$?
  if [ "$remote_status" -ne 1 ]; then
    exit "$remote_status"
  fi

  builder_iid="$run_root/builder.iid"

  docker build \
    --platform "$platform" \
    --build-arg "OPENAGENTS_BUILD_REVISION=$git_sha" \
    --build-arg "SOURCE_DATE_EPOCH=$source_date_epoch" \
    --iidfile "$builder_iid" \
    --label "org.opencontainers.image.revision=$git_sha" \
    --tag "$builder_tag" \
    --target forge-builder \
    "$repo_root"

  docker push "$builder_tag" >/dev/null
  builder_digest=$(remote_digest "$builder_tag" builder)
fi

case "$application_digest" in
  sha256:????????????????????????????????????????????????????????????????) ;;
  *) echo "application registry manifest digest is invalid" >&2; exit 1 ;;
esac

case "$builder_digest" in
  sha256:????????????????????????????????????????????????????????????????) ;;
  *) echo "builder registry manifest digest is invalid" >&2; exit 1 ;;
esac

application_image="${application_repository}@${application_digest}"
builder_image="${builder_repository}@${builder_digest}"

docker pull --platform "$platform" "$application_image" >/dev/null
docker pull --platform "$platform" "$builder_image" >/dev/null
verify_platform "$application_image"
verify_platform "$builder_image"

application_revision=$(
  docker image inspect "$application_image" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
)

builder_revision=$(
  docker image inspect "$builder_image" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
)

if [ "$application_revision" != "$git_sha" ] || [ "$builder_revision" != "$git_sha" ]; then
  echo "registry image revision labels do not match the exact Git SHA" >&2
  exit 1
fi

embedded_application_revision=$(
  docker run --rm \
    --entrypoint /bin/sh \
    "$application_image" \
    -c 'release_version=$(awk '\''{print $2}'\'' /app/releases/start_erl.data); /app/erts-*/bin/erl -boot_var RELEASE_LIB /app/lib -boot "/app/releases/$release_version/start_clean" -noshell -pa /app/lib/openagents-*/ebin -eval "io:put_chars('\''Elixir.OpenAgents.BuildInfo'\'':revision()), halt()."' \
    | tail -n 1
)

embedded_builder_revision=$(
  docker run --rm \
    --entrypoint /bin/sh \
    "$builder_image" \
    -c 'elixir -pa /app/_build/prod/lib/openagents/ebin -e "IO.write(OpenAgents.BuildInfo.revision())"'
)

if [ "$embedded_application_revision" != "$git_sha" ] ||
  [ "$embedded_builder_revision" != "$git_sha" ]; then
  echo "registry image packaged revisions do not match the exact Git SHA" >&2
  exit 1
fi

docker run --rm \
  --entrypoint /bin/sh \
  "$application_image" \
  -c 'set -eu
      test -x /usr/local/lib/codex-package/bin/codex
      test -x /usr/local/lib/codex-package/bin/codex-code-mode-host
      test -x /usr/local/lib/codex-package/codex-resources/bwrap
      test -x /usr/local/lib/codex-package/codex-path/rg
      /usr/local/lib/codex-package/bin/codex-code-mode-host --help >/dev/null'

application_config_digest=$(docker image inspect "$application_image" --format '{{.Id}}')
builder_config_digest=$(docker image inspect "$builder_image" --format '{{.Id}}')

archive_name=$(
  docker run --rm \
    --entrypoint /bin/sh \
    "$builder_image" \
    -c 'set -- /app/_build/prod/openagents-*.tar.gz; [ "$#" -eq 1 ]; basename "$1"'
)

case "$archive_name" in
  openagents-*.tar.gz) ;;
  *) echo "builder image does not contain one release archive" >&2; exit 1 ;;
esac

release_version=${archive_name#openagents-}
release_version=${release_version%.tar.gz}
builder_container=$(docker create "$builder_image")
docker cp "$builder_container:/app/_build/prod/$archive_name" "$candidate_temp/$archive_name" >/dev/null
docker rm "$builder_container" >/dev/null
builder_container=

ops/staging/generate-sbom.sh \
  "$application_image" \
  "$candidate_temp/sbom.cdx.json"

release_sha256=$(sha256sum "$candidate_temp/$archive_name" | cut -d ' ' -f 1)
sbom_sha256=$(sha256sum "$candidate_temp/sbom.cdx.json" | cut -d ' ' -f 1)
sbom_receipt_sha256=$(sha256sum "$candidate_temp/sbom.cdx.json.receipt" | cut -d ' ' -f 1)
gate_receipt="$git_common_dir/openagents/release-gate-receipts/$git_sha.json"
gate_receipt_sha256=$(sha256sum "$gate_receipt" | cut -d ' ' -f 1)
dockerfile_sha256=$(sha256sum "$repo_root/Dockerfile" | cut -d ' ' -f 1)
mix_lock_sha256=$(sha256sum "$repo_root/mix.lock" | cut -d ' ' -f 1)
lineage_map_sha256=$(sha256sum "$repo_root/priv/migration_lineages/prior-2026-08-19.json" | cut -d ' ' -f 1)
application_spec_sha256=$(
  docker run --rm \
    --entrypoint /bin/sh \
    "$builder_image" \
    -c 'sha256sum /app/_build/prod/lib/openagents/ebin/openagents.app' \
    | cut -d ' ' -f 1
)
elixir_version=$(docker run --rm --entrypoint elixir "$builder_image" --version | awk '/^Elixir / {print $2}')
otp_release=$(docker run --rm --entrypoint elixir "$builder_image" --version | awk '/^Erlang\/OTP / {print $2}')
erts_version=$(
  docker run --rm --entrypoint erl "$builder_image" \
    -noshell -eval 'io:put_chars(erlang:system_info(version)), halt().'
)
generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
manifest_temp="$candidate_temp/candidate-manifest.json.tmp"

jq -n \
  --arg git_sha "$git_sha" \
  --arg generated_at "$generated_at" \
  --argjson source_date_epoch "$source_date_epoch" \
  --arg staging_project "$staging_project" \
  --arg region "$region" \
  --arg platform "$platform" \
  --arg application_tag "$application_tag" \
  --arg application_image "$application_image" \
  --arg application_digest "$application_digest" \
  --arg application_config_digest "$application_config_digest" \
  --arg builder_tag "$builder_tag" \
  --arg builder_image "$builder_image" \
  --arg builder_digest "$builder_digest" \
  --arg builder_config_digest "$builder_config_digest" \
  --arg release_version "$release_version" \
  --arg release_file "$archive_name" \
  --arg release_sha256 "$release_sha256" \
  --arg sbom_sha256 "$sbom_sha256" \
  --arg sbom_receipt_sha256 "$sbom_receipt_sha256" \
  --arg gate_receipt_sha256 "$gate_receipt_sha256" \
  --arg dockerfile_sha256 "$dockerfile_sha256" \
  --arg mix_lock_sha256 "$mix_lock_sha256" \
  --arg lineage_map_sha256 "$lineage_map_sha256" \
  --arg elixir_version "$elixir_version" \
  --arg otp_release "$otp_release" \
  --arg erts_version "$erts_version" \
  --arg application_spec_sha256 "$application_spec_sha256" '
  {
    schema: "openagents.staging-candidate.v1",
    git_sha: $git_sha,
    branch: "main",
    generated_at: $generated_at,
    source_date_epoch: $source_date_epoch,
    target: {
      environment: "staging",
      project: $staging_project,
      region: $region,
      platform: $platform,
      immutable_tags: true
    },
    images: {
      application: {
        tag: $application_tag,
        reference: $application_image,
        manifest_digest: $application_digest,
        config_digest: $application_config_digest
      },
      builder: {
        tag: $builder_tag,
        reference: $builder_image,
        manifest_digest: $builder_digest,
        config_digest: $builder_config_digest
      }
    },
    release: {
      version: $release_version,
      file: $release_file,
      sha256: $release_sha256
    },
    sbom: {
      file: "sbom.cdx.json",
      sha256: $sbom_sha256,
      receipt_sha256: $sbom_receipt_sha256
    },
    receipts: {
      release_gate_sha256: $gate_receipt_sha256
    },
    inputs: {
      dockerfile_sha256: $dockerfile_sha256,
      mix_lock_sha256: $mix_lock_sha256,
      migration_lineage_map_sha256: $lineage_map_sha256,
      application_spec_sha256: $application_spec_sha256
    },
    toolchain: {
      elixir: $elixir_version,
      otp: $otp_release,
      erts: $erts_version
    }
  }
' >"$manifest_temp"

mv "$manifest_temp" "$candidate_temp/candidate-manifest.json"
manifest_sha256=$(sha256sum "$candidate_temp/candidate-manifest.json" | cut -d ' ' -f 1)
printf '%s  candidate-manifest.json\n' "$manifest_sha256" \
  >"$candidate_temp/candidate-manifest.sha256"

jq -e \
  --arg sha "$git_sha" \
  --arg application_digest "$application_digest" \
  --arg builder_digest "$builder_digest" '
  .schema == "openagents.staging-candidate.v1" and
  .git_sha == $sha and
  .target.environment == "staging" and
  .target.immutable_tags == true and
  .images.application.manifest_digest == $application_digest and
  .images.builder.manifest_digest == $builder_digest and
  (.release.sha256 | test("^[0-9a-f]{64}$")) and
  (.sbom.sha256 | test("^[0-9a-f]{64}$"))
' "$candidate_temp/candidate-manifest.json" >/dev/null

mv "$candidate_temp" "$candidate_path"
candidate_temp=
trap - EXIT INT TERM
find "$run_root" -depth -delete

echo "Published immutable staging candidate $git_sha"
echo "Application: $application_image"
echo "Builder: $builder_image"
echo "Evidence: .git/openagents/staging-candidates/$git_sha"
