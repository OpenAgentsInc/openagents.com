#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
git_common_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)

proof_key() {
  git_sha=$(git -C "$repo_root" rev-parse --verify HEAD)

  if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]; then
    if [ "${OPENAGENTS_RELUP_PROOF_ALLOW_DIRTY:-}" != "1" ]; then
      echo "relup proof requires a clean worktree" >&2
      exit 1
    fi

    dirty_digest=$(
      {
        git -C "$repo_root" diff --binary HEAD
        git -C "$repo_root" ls-files --others --exclude-standard | sort | while IFS= read -r file; do
          printf '%s\n' "$file"
          sha256sum "$repo_root/$file"
        done
      } | sha256sum | cut -d ' ' -f 1
    )
    printf '%s\n' "worktree-$git_sha-$dirty_digest"
  else
    printf '%s\n' "$git_sha"
  fi
}

proof_root() {
  key=$(proof_key) || return $?
  printf '%s\n' "$git_common_dir/openagents/relup-proof/$key"
}

require_proof_artifacts() {
  artifact_root=$(proof_root)

  for artifact in openagents-0.1.0.tar.gz openagents-0.2.0.tar.gz relup proof.json; do
    if [ ! -f "$artifact_root/$artifact" ]; then
      echo "missing relup proof artifact: $artifact" >&2
      echo "run ops/relup-proof/run.sh first" >&2
      exit 1
    fi
  done
}

require_disposable_database() {
  if [ "${OPENAGENTS_RELUP_PROOF_DISPOSABLE:-}" != "1" ]; then
    echo "set OPENAGENTS_RELUP_PROOF_DISPOSABLE=1 for a disposable database" >&2
    exit 1
  fi

  proof_database_url=${OPENAGENTS_RELUP_PROOF_DATABASE_URL:-${OPENAGENTS_RELEASE_SMOKE_DATABASE_URL:-}}

  if [ -z "$proof_database_url" ]; then
    echo "OPENAGENTS_RELUP_PROOF_DATABASE_URL is required" >&2
    exit 1
  fi
}

prepare_runtime() {
  require_proof_artifacts
  require_disposable_database

  runtime_root=$(mktemp -d /tmp/openagents-relup-runtime.XXXXXX)
  tar -xzf "$artifact_root/openagents-0.1.0.tar.gz" -C "$runtime_root"
  cp "$artifact_root/openagents-0.2.0.tar.gz" "$runtime_root/releases/openagents-0.2.0.tar.gz"

  release_bin="$runtime_root/bin/openagents"
  release_log="$runtime_root/release.log"
  release_pid=
  proof_port=$((42000 + ($$ % 10000)))
  proof_secret=$(openssl rand -base64 64 | tr -d '\n')
  proof_token_key=$(openssl rand -base64 32 | tr -d '\n')
  # The content vault's own key (VAULT-001, issue #193). Nothing bridges
  # to it, so the proof supplies one or the release refuses to boot.
  proof_content_key=$(openssl rand -base64 32 | tr -d '\n')
}

profile() {
  env \
    DATABASE_URL="$proof_database_url" \
    GITHUB_CLIENT_ID="relup-proof-client" \
    GITHUB_CLIENT_SECRET="relup-proof-secret" \
    GITHUB_TOKEN_ENCRYPTION_KEY="$proof_token_key" \
    GITHUB_TOKEN_ENCRYPTION_KEY_ID="staging-relup-proof-2026-08" \
    CONTENT_ENCRYPTION_KEY="$proof_content_key" \
    OPENAI_API_KEY="relup-proof-openai-key" \
    OPENAGENTS_RELUP_INSTALL_BARRIER_MS="${OPENAGENTS_RELUP_INSTALL_BARRIER_MS:-0}" \
    OPENAGENTS_RELUP_INSTALL_BARRIER_PATH="${OPENAGENTS_RELUP_INSTALL_BARRIER_PATH:-}" \
    PHX_SERVER="true" \
    POOL_SIZE="2" \
    PORT="$proof_port" \
    RELEASE_DISTRIBUTION="name" \
    RELEASE_NODE="openagents@127.0.0.1" \
    SECRET_KEY_BASE="$proof_secret" \
    "$repo_root/ops/staging/gate-5-profile.sh" "$@"
}

start_release() {
  profile "$release_bin" start >"$release_log" 2>&1 &
  release_pid=$!

  attempt=0
  until profile "$release_bin" rpc 'if Process.whereis(OpenAgents.ReleaseState), do: IO.puts("relup-proof-ready")' 2>/dev/null | grep -q 'relup-proof-ready'; do
    attempt=$((attempt + 1))

    if ! kill -0 "$release_pid" 2>/dev/null; then
      echo "relup proof release exited during startup" >&2
      tail -80 "$release_log" >&2
      exit 1
    fi

    if [ "$attempt" -ge 120 ]; then
      echo "relup proof release did not become reachable" >&2
      tail -80 "$release_log" >&2
      exit 1
    fi

    sleep 0.5
  done
}

stop_release() {
  if [ -n "${release_pid:-}" ] && kill -0 "$release_pid" 2>/dev/null; then
    profile "$release_bin" stop >/dev/null 2>&1 || kill -TERM "$release_pid" 2>/dev/null || true
    wait "$release_pid" 2>/dev/null || true
  fi

  release_pid=
}

cleanup_runtime() {
  stop_release

  if [ -n "${runtime_root:-}" ] && [ -d "$runtime_root" ]; then
    find "$runtime_root" -depth -delete
  fi
}

rpc_assert() {
  expression=$1
  expected=$2
  output=$(profile "$release_bin" rpc "$expression")

  if ! printf '%s\n' "$output" | grep -Fq "$expected"; then
    echo "relup RPC assertion failed: expected $expected" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

unpack_and_check_candidate() {
  rpc_assert ':release_handler.unpack_release(~c"openagents-0.2.0") |> IO.inspect(label: "unpack")' 'unpack: {:ok, ~c"0.2.0"}'
  rpc_assert 'Castle.generate("0.2.0"); :release_handler.check_install_release(~c"0.2.0") |> IO.inspect(label: "check")' 'check: {:ok, ~c"0.1.0"'
}
