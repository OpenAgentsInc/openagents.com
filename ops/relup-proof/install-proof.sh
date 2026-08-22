#!/bin/sh
# Installs an already-packaged two-way relup against a live single-node
# release, proving forward upgrade, reverse rollback, and re-upgrade with
# ReleaseState retention. Consumes the output of ops/forge/package-relup.sh,
# including its versions and state schemas, so the assertions describe the
# package actually under test rather than a hardcoded pair.
#
# This script creates and drops a database. It refuses to run unless
# OPENAGENTS_RELUP_PROOF_DISPOSABLE=1, the URL host is loopback, and the
# database name contains `proof`, `smoke`, or `test`. It performs every one of
# those checks before it arms its cleanup trap, so a refused run destroys
# nothing.
#
# Required environment: OPENAGENTS_RELUP_PROOF_DISPOSABLE=1 and
# OPENAGENTS_RELUP_PROOF_DATABASE_URL.
#
# Optional: RELUP_PROOF_PACKAGE_DIR, RELUP_PROOF_NODE, RELUP_PROOF_PORT.
#
# Every release_handler call records its result to a file on the node and the
# assertion reads that file back. The rpc channel's IO can drop mid-call while
# release_handler suspends processes, so the shell cannot trust what it saw on
# stdout; it can trust what the node wrote. The reverse leg asserts exactly
# what OpenAgents.Forge.RelupNode.verify_reverse_health/2 asserts: the from
# release is current or permanent, the node reports ready, and the process
# state carries the packaged from_state_version.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
pkg="${RELUP_PROOF_PACKAGE_DIR:-$repo_root/.git/openagents/relup-package}"
node_name="${RELUP_PROOF_NODE:-openagents-relup-proof@127.0.0.1}"

if [ "${OPENAGENTS_RELUP_PROOF_DISPOSABLE:-}" != "1" ]; then
  echo "set OPENAGENTS_RELUP_PROOF_DISPOSABLE=1 for a disposable database" >&2
  exit 1
fi

proof_database_url=${OPENAGENTS_RELUP_PROOF_DATABASE_URL:-}
if [ -z "$proof_database_url" ]; then
  echo "OPENAGENTS_RELUP_PROOF_DATABASE_URL is required" >&2
  exit 1
fi

authority=${proof_database_url#*://}
db_path=${authority#*/}
authority=${authority%%/*}
host_port=${authority##*@}
db_host=${host_port%%:*}
db_name=${db_path%%\?*}

case "$host_port" in
  *:*) db_port=${host_port##*:} ;;
  *) db_port=5432 ;;
esac

case "$db_host" in
  localhost | 127.0.0.1) : ;;
  *)
    echo "refusing: the proof database host must be loopback, got $db_host" >&2
    exit 1
    ;;
esac

case "$db_name" in
  *proof* | *smoke* | *test*) : ;;
  *)
    echo "refusing: the proof database name must contain proof, smoke, or test" >&2
    exit 1
    ;;
esac

if [ ! -f "$pkg/package.json" ]; then
  echo "missing relup package: $pkg/package.json" >&2
  echo "run ops/forge/package-relup.sh --out-dir $pkg first" >&2
  exit 1
fi

package_field() {
  sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}[[:space:]]*$/\1/p" \
    "$pkg/package.json" | head -1
}

from_version=$(package_field from_version)
to_version=$(package_field to_version)
from_state=$(package_field from_state_version)
to_state=$(package_field to_state_version)

for field in "$from_version" "$to_version" "$from_state" "$to_state"; do
  [ -n "$field" ] || { echo "package.json is missing a required field" >&2; exit 1; }
done

runtime_root=$(mktemp -d /tmp/openagents-relup-runtime.XXXXXX)
release_log="$runtime_root/release.log"
result_file="$runtime_root/handler-result"
release_pid=

cleanup() {
  if [ -n "${release_pid:-}" ]; then
    profile "$runtime_root/bin/openagents" stop >/dev/null 2>&1 || true
    kill -TERM "$release_pid" 2>/dev/null || true
  fi
  [ -d "$runtime_root" ] && find "$runtime_root" -depth -delete
  dropdb -h "$db_host" -p "$db_port" --if-exists "$db_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

pkill -f "$node_name" 2>/dev/null || true
sleep 1

dropdb -h "$db_host" -p "$db_port" --if-exists "$db_name" >/dev/null 2>&1 || true
createdb -h "$db_host" -p "$db_port" "$db_name"

tar -xzf "$pkg/openagents-$from_version.tar.gz" -C "$runtime_root"
cp "$pkg/openagents-$to_version.tar.gz" "$runtime_root/releases/openagents-$to_version.tar.gz"

secret=$(openssl rand -base64 64 | tr -d '\n')
token_key=$(openssl rand -base64 32 | tr -d '\n')

profile() {
  env \
    DATABASE_URL="$proof_database_url" \
    GITHUB_CLIENT_ID="relup-proof-client" \
    GITHUB_CLIENT_SECRET="relup-proof-secret" \
    GITHUB_TOKEN_ENCRYPTION_KEY="$token_key" \
    GITHUB_TOKEN_ENCRYPTION_KEY_ID="staging-relup-proof-2026-08" \
    OPENAI_API_KEY="relup-proof-openai-key" \
    PHX_SERVER="true" \
    POOL_SIZE="2" \
    PORT="${RELUP_PROOF_PORT:-4399}" \
    RELEASE_DISTRIBUTION="name" \
    RELEASE_NODE="$node_name" \
    SECRET_KEY_BASE="$secret" \
    "$repo_root/ops/staging/gate-5-profile.sh" "$@"
}

fail() {
  echo "PROOF FAILED: $1"
  tail -40 "$runtime_root/log" 2>/dev/null || true
  tail -40 "$release_log" 2>/dev/null || true
  exit 1
}

bin="$runtime_root/bin/openagents"

# Runs one expression on the node and returns its inspected result through a
# file, so a dropped rpc channel cannot be mistaken for a successful call.
handler_result=""

record() {
  rm -f "$result_file"
  profile "$bin" rpc "File.write!(\"$result_file\", inspect($1))" >/dev/null 2>&1 || true

  attempt=0
  until [ -f "$result_file" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -ge 240 ] && fail "the node recorded no result for: $1"
    kill -0 "$release_pid" 2>/dev/null || fail "the node exited during: $1"
    sleep 0.5
  done

  handler_result=$(cat "$result_file")
}

assert_result() {
  record "$1"

  case "$handler_result" in
    *"$2"*) echo "  $3: $handler_result" ;;
    *) fail "$3 returned $handler_result, expected $2" ;;
  esac
}

echo "proving $from_version -> $to_version (state $from_state -> $to_state)"
echo "starting $from_version"
profile "$bin" start >"$release_log" 2>&1 &
release_pid=$!

attempt=0
until profile "$bin" rpc 'if Process.whereis(OpenAgents.ReleaseState), do: IO.puts("ready-marker")' 2>/dev/null | grep -q ready-marker; do
  attempt=$((attempt + 1))
  [ $attempt -ge 120 ] && fail "release never became reachable"
  kill -0 "$release_pid" 2>/dev/null || fail "release exited during startup"
  sleep 0.5
done

echo "recording state on $from_version"
assert_result "(OpenAgents.ReleaseState.observe(\"retained-through-$to_version\"))" ":ok" "observe"

echo "unpacking $to_version"
assert_result ":release_handler.unpack_release(~c\"openagents-$to_version\")" \
  "{:ok, ~c\"$to_version\"}" "unpack_release"

echo "installing $to_version"
assert_result "(Castle.generate(\"$to_version\"); :release_handler.install_release(~c\"$to_version\"))" \
  "{:ok, ~c\"$from_version\"" "install_release"

assert_result "to_string(Application.spec(:openagents, :vsn))" "\"$to_version\"" "running version"
assert_result "OpenAgents.ReleaseState.snapshot().schema_version" "$to_state" "forward state schema"
assert_result "Enum.member?(OpenAgents.ReleaseState.snapshot().observations, \"retained-through-$to_version\")" \
  "true" "forward observations"
assert_result "OpenAgents.Cluster.local_report()[\"ready\"]" "true" "forward health"

assert_result ":release_handler.make_permanent(~c\"$to_version\")" ":ok" "make_permanent"
assert_result "Enum.find_value(:release_handler.which_releases(), fn {_, v, _, s} -> if to_string(v) == \"$to_version\", do: s end)" \
  ":permanent" "forward permanence"

echo "reversing to $from_version"
# RelupNode.reverse/2 does not regenerate configuration for the from release,
# so neither does this leg.
assert_result ":release_handler.install_release(~c\"$from_version\")" \
  "{:ok, " "reverse install_release"

# The three checks RelupNode.verify_reverse_health/2 makes, in its order.
record "Enum.find_value(:release_handler.which_releases(), fn {_, v, _, s} -> if to_string(v) == \"$from_version\", do: s end)"

case "$handler_result" in
  :current | :permanent) echo "  reverse release status: $handler_result" ;;
  *) fail "reverse left $from_version at $handler_result, expected :current or :permanent" ;;
esac

assert_result "OpenAgents.Cluster.local_report()[\"ready\"]" "true" "reverse health"
assert_result "OpenAgents.ReleaseState.snapshot().schema_version" "$from_state" "reverse state schema"
assert_result "Enum.member?(OpenAgents.ReleaseState.snapshot().observations, \"retained-through-$to_version\")" \
  "true" "reverse observations"

assert_result ":release_handler.make_permanent(~c\"$from_version\")" ":ok" "reverse make_permanent"
assert_result "Enum.find_value(:release_handler.which_releases(), fn {_, v, _, s} -> if to_string(v) == \"$from_version\", do: s end)" \
  ":permanent" "reverse permanence"

echo "re-upgrading to $to_version"
assert_result "(Castle.generate(\"$to_version\"); :release_handler.install_release(~c\"$to_version\"))" \
  "{:ok, ~c\"$from_version\"" "re-upgrade install_release"

assert_result "to_string(Application.spec(:openagents, :vsn))" "\"$to_version\"" "re-upgrade running version"
assert_result "OpenAgents.ReleaseState.snapshot().schema_version" "$to_state" "re-upgrade state schema"
assert_result ":release_handler.make_permanent(~c\"$to_version\")" ":ok" "re-upgrade make_permanent"

echo ""
echo "GENERALIZED RELUP PROOF PASSED"
echo "forward $from_version->$to_version, reverse, and re-upgrade all installed hot;"
echo "each release_handler result and both state schemas were asserted."
