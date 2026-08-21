#!/bin/sh
# Installs an already-packaged two-way relup against a live single-node
# release, proving forward upgrade, reverse rollback, and re-upgrade with
# ReleaseState retention. Consumes the output of ops/forge/package-relup.sh.
#
# Required environment: OPENAGENTS_RELUP_PROOF_DISPOSABLE=1 and
# OPENAGENTS_RELUP_PROOF_DATABASE_URL (a disposable PostgreSQL URL),
# matching the contract of ops/relup-proof/run.sh.
#
# Optional: RELUP_PROOF_PACKAGE_DIR, RELUP_PROOF_NODE, RELUP_PROOF_PORT.
# Install proof for a generalized relup pair: 0.2.0 -> 0.3.0 -> reverse ->
# re-upgrade, using the tarballs produced by ops/forge/package-relup.sh.
#
# Assertions check observable effects (directories, running version, retained
# state) rather than release_handler return values relayed through the shell
# rpc channel, whose IO can drop mid-call while release_handler runs.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
pkg="${RELUP_PROOF_PACKAGE_DIR:-$repo_root/.git/openagents/relup-package}"
runtime_root=$(mktemp -d /tmp/openagents-relup-runtime.XXXXXX)
release_log="$runtime_root/release.log"
node_name="${RELUP_PROOF_NODE:-openagents-relup-proof@127.0.0.1}"
db="${RELUP_PROOF_DB:-openagents_relup_proof}"

cleanup() {
  if [ -n "${release_pid:-}" ]; then
    profile "$runtime_root/bin/openagents" stop >/dev/null 2>&1 || true
    kill -TERM "$release_pid" 2>/dev/null || true
  fi
  [ -d "$runtime_root" ] && find "$runtime_root" -depth -delete
  dropdb -h localhost --if-exists "$db" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if [ "${OPENAGENTS_RELUP_PROOF_DISPOSABLE:-}" != "1" ]; then
  echo "set OPENAGENTS_RELUP_PROOF_DISPOSABLE=1 for a disposable database" >&2
  exit 1
fi

proof_database_url=${OPENAGENTS_RELUP_PROOF_DATABASE_URL:-}
[ -n "$proof_database_url" ] || {
  echo "OPENAGENTS_RELUP_PROOF_DATABASE_URL is required" >&2
  exit 1
}

pkill -f "$node_name" 2>/dev/null || true
sleep 1

db_name=$(printf '%s' "$proof_database_url" | sed -E 's|.*/||')
dropdb -h localhost --if-exists "$db_name" >/dev/null 2>&1 || true
createdb -h localhost "$db_name"

tar -xzf "$pkg/openagents-0.2.0.tar.gz" -C "$runtime_root"
cp "$pkg/openagents-0.3.0.tar.gz" "$runtime_root/releases/openagents-0.3.0.tar.gz"

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
  exit 1
}

bin="$runtime_root/bin/openagents"

echo "starting 0.2.0"
profile "$bin" start >"$release_log" 2>&1 &
release_pid=$!

attempt=0
until profile "$bin" rpc 'if Process.whereis(OpenAgents.ReleaseState), do: IO.puts("ready-marker")' 2>/dev/null | grep -q ready-marker; do
  attempt=$((attempt + 1))
  [ $attempt -ge 120 ] && fail "release never became reachable"
  kill -0 "$release_pid" 2>/dev/null || fail "release exited during startup"
  sleep 0.5
done

echo "recording state on 0.2.0"
out=$(profile "$bin" rpc 'OpenAgents.ReleaseState.observe("retained-through-0.3.0"); IO.puts("observed")' 2>/dev/null)
echo "$out" | grep -q observed || fail "observe failed: $out"

echo "unpacking 0.3.0"
profile "$bin" rpc ':release_handler.unpack_release(:binary.bin_to_list("openagents-0.3.0"))' >/dev/null 2>&1 || true
[ -d "$runtime_root/releases/0.3.0" ] || fail "unpack produced no releases/0.3.0 directory"

echo "installing 0.3.0"
profile "$bin" rpc 'Castle.generate("0.3.0"); :release_handler.install_release(:binary.bin_to_list("0.3.0"))' >/dev/null 2>&1 || true

out=$(profile "$bin" rpc 'IO.puts(to_string(Application.spec(:openagents, :vsn)))' 2>/dev/null)
echo "$out" | grep -q "0.3.0" || fail "running version did not become 0.3.0: $out"

out=$(profile "$bin" rpc 'IO.puts(inspect({OpenAgents.ReleaseState.snapshot().schema_version, Enum.any?(OpenAgents.ReleaseState.snapshot().observations, &(&1 == "retained-through-0.3.0"))}))' 2>/dev/null)
echo "$out" | grep -qF "{2, true}" || fail "state did not survive the upgrade: $out"

profile "$bin" rpc ':release_handler.make_permanent(:binary.bin_to_list("0.3.0"))' >/dev/null 2>&1 || true
echo "0.3.0 installed live and made permanent; observations survived"

echo "reversing to 0.2.0"
profile "$bin" rpc ':release_handler.install_release(:binary.bin_to_list("0.2.0")); :release_handler.make_permanent(:binary.bin_to_list("0.2.0"))' >/dev/null 2>&1 || true

out=$(profile "$bin" rpc 'IO.puts(to_string(Application.spec(:openagents, :vsn)))' 2>/dev/null)
echo "$out" | grep -q "0.2.0" || fail "reverse did not restore 0.2.0: $out"

out=$(profile "$bin" rpc 'IO.puts(inspect(Enum.any?(OpenAgents.ReleaseState.snapshot().observations, &(&1 == "retained-through-0.3.0"))))' 2>/dev/null)
echo "$out" | grep -qF "true" || fail "observations did not survive the reverse"

echo "re-upgrading to 0.3.0"
profile "$bin" rpc ':release_handler.install_release(:binary.bin_to_list("0.3.0")); :release_handler.make_permanent(:binary.bin_to_list("0.3.0"))' >/dev/null 2>&1 || true

out=$(profile "$bin" rpc 'IO.puts(to_string(Application.spec(:openagents, :vsn)))' 2>/dev/null)
echo "$out" | grep -q "0.3.0" || fail "re-upgrade did not restore 0.3.0: $out"

echo ""
echo "GENERALIZED RELUP PROOF PASSED"
echo "forward 0.2.0->0.3.0, reverse, and re-upgrade all installed hot;"
echo "ReleaseState observations survived every transition."
