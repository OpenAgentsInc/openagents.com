#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/common.sh"

prepare_runtime
barrier_path="$runtime_root/install-barrier-entered"
export OPENAGENTS_RELUP_INSTALL_BARRIER_MS=30000
export OPENAGENTS_RELUP_INSTALL_BARRIER_PATH="$barrier_path"
install_client_pid=

cleanup() {
  if [ -n "${install_client_pid:-}" ]; then
    kill -TERM "$install_client_pid" 2>/dev/null || true
    wait "$install_client_pid" 2>/dev/null || true
  fi

  cleanup_runtime
}

trap cleanup EXIT INT TERM
start_release
unpack_and_check_candidate

profile "$release_bin" rpc ':release_handler.install_release(~c"0.2.0") |> IO.inspect(label: "interrupted_install")' >/dev/null 2>&1 &
install_client_pid=$!

attempt=0
until [ -f "$barrier_path" ]; do
  attempt=$((attempt + 1))

  if [ "$attempt" -ge 120 ]; then
    echo "install barrier was not reached" >&2
    tail -80 "$release_log" >&2
    exit 1
  fi

  sleep 0.25
done

runtime_pid=$(profile "$release_bin" pid | tail -1)
kill -KILL "$runtime_pid"
wait "$release_pid" 2>/dev/null || true
release_pid=
wait "$install_client_pid" 2>/dev/null || true
install_client_pid=

rm -f "$runtime_root/releases/openagents-0.2.0.tar.gz"
cp "$artifact_root/openagents-0.2.0.tar.gz" "$runtime_root/releases/openagents-0.2.0.tar.gz"

start_release
rpc_assert ':release_handler.which_releases(:permanent) |> IO.inspect(label: "permanent_after_kill")' '~c"0.1.0"'

rpc_assert '
  known = Enum.any?(:release_handler.which_releases(), fn {_, version, _, _} -> version == ~c"0.2.0" end)
  result = if known, do: {:ok, ~c"0.2.0"}, else: :release_handler.unpack_release(~c"openagents-0.2.0")
  IO.inspect(result, label: "restaged")
' 'restaged: {:ok, ~c"0.2.0"}'

rpc_assert 'Castle.generate("0.2.0"); :release_handler.check_install_release(~c"0.2.0") |> IO.inspect(label: "retry_check")' 'retry_check: {:ok, ~c"0.1.0"'
rpc_assert ':release_handler.install_release(~c"0.2.0") |> IO.inspect(label: "retry_install")' 'retry_install: {:ok, ~c"0.1.0"'
rpc_assert ':release_handler.make_permanent(~c"0.2.0") |> IO.inspect(label: "retry_commit")' 'retry_commit: :ok'
rpc_assert ':release_handler.which_releases(:permanent) |> IO.inspect(label: "permanent_after_retry")' '~c"0.2.0"'

echo "Interrupted relup install recovery proof passed"
