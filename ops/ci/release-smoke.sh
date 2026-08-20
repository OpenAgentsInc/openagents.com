#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
release_bin="$repo_root/_build/prod/rel/openagents/bin/openagents"
release_readiness="$repo_root/_build/prod/rel/openagents/bin/config-readiness"
staging_profile="$repo_root/ops/staging/gate-5-profile.sh"
database_url=${OPENAGENTS_RELEASE_SMOKE_DATABASE_URL:-}
disposable=${OPENAGENTS_RELEASE_SMOKE_DISPOSABLE:-}
port=${OPENAGENTS_RELEASE_SMOKE_PORT:-$((40000 + ($$ % 20000)))}
release_pid=
assets_digested=0
smoke_root=$(mktemp -d /tmp/openagents-release-smoke.XXXXXX)
release_log="$smoke_root/release.log"

cleanup() {
  if [ -n "$release_pid" ] && kill -0 "$release_pid" 2>/dev/null; then
    kill -TERM "$release_pid" 2>/dev/null || true
    wait "$release_pid" 2>/dev/null || true
  fi

  if [ "$assets_digested" = "1" ]; then
    (cd "$repo_root" && MIX_ENV=prod mix phx.digest.clean --all >/dev/null 2>&1) || true
  fi

  find "$smoke_root" -depth -delete
}

trap cleanup EXIT INT TERM

if [ ! -d "$repo_root/.git" ]; then
  echo "release smoke must run from a Git worktree" >&2
  exit 1
fi

if [ "$disposable" != "1" ]; then
  echo "set OPENAGENTS_RELEASE_SMOKE_DISPOSABLE=1 after you provision a disposable database" >&2
  exit 1
fi

if [ -z "$database_url" ]; then
  echo "OPENAGENTS_RELEASE_SMOKE_DATABASE_URL is required" >&2
  exit 1
fi

for command_name in curl jq openssl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required for the release smoke" >&2
    exit 1
  fi
done

cd "$repo_root"

echo "Building production assets and release"
assets_digested=1
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite

secret_key_base=$(openssl rand -base64 64 | tr -d '\n')
github_token_key=$(openssl rand -base64 32 | tr -d '\n')

echo "Checking the release configuration profile"
readiness_report=$(env \
  DATABASE_URL="$database_url" \
  GITHUB_CLIENT_ID="release-smoke-client" \
  GITHUB_CLIENT_SECRET="release-smoke-secret" \
  GITHUB_TOKEN_ENCRYPTION_KEY="$github_token_key" \
  GITHUB_TOKEN_ENCRYPTION_KEY_ID="staging-release-smoke-2026-08" \
  OPENAI_API_KEY="release-smoke-openai-key" \
  POOL_SIZE="2" \
  PORT="$port" \
  SECRET_KEY_BASE="$secret_key_base" \
  "$staging_profile" "$release_readiness")

echo "$readiness_report" | jq -e '
  .schema == "openagents.runtime_configuration.v1" and
  .status == "ready" and
  .environment == "staging" and
  .staging_gate == 5
' >/dev/null

echo "Starting release against the disposable database"
env \
  DATABASE_URL="$database_url" \
  GITHUB_CLIENT_ID="release-smoke-client" \
  GITHUB_CLIENT_SECRET="release-smoke-secret" \
  GITHUB_TOKEN_ENCRYPTION_KEY="$github_token_key" \
  GITHUB_TOKEN_ENCRYPTION_KEY_ID="staging-release-smoke-2026-08" \
  OPENAI_API_KEY="release-smoke-openai-key" \
  PHX_SERVER="true" \
  POOL_SIZE="2" \
  PORT="$port" \
  SECRET_KEY_BASE="$secret_key_base" \
  "$staging_profile" "$release_bin" start >"$release_log" 2>&1 &
release_pid=$!

health_url="http://127.0.0.1:$port/health"
health_body=

for attempt in $(seq 1 120); do
  if ! kill -0 "$release_pid" 2>/dev/null; then
    echo "release exited before it became healthy" >&2
    tail -40 "$release_log" >&2
    exit 1
  fi

  if health_body=$(curl --fail --silent --show-error --max-time 2 "$health_url" 2>/dev/null); then
    break
  fi

  sleep 0.5
done

case "$health_body" in
  *'"status":"ok"'*) ;;
  *)
    echo "release did not return the expected bounded health response" >&2
    tail -40 "$release_log" >&2
    exit 1
    ;;
esac

kill -TERM "$release_pid"
wait "$release_pid"
release_pid=

echo "Release startup smoke passed"
