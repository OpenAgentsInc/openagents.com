#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/common.sh"

prepare_runtime
trap cleanup_runtime EXIT INT TERM
start_release

rpc_assert ':release_handler.which_releases(:permanent) |> IO.inspect(label: "permanent")' '~c"0.1.0"'
rpc_assert 'OpenAgents.ReleaseState.observe("retained-through-relup"); IO.puts("observed")' 'observed'
state_pid=$(profile "$release_bin" rpc 'OpenAgents.ReleaseState |> Process.whereis() |> :erlang.pid_to_list() |> IO.puts()' | tail -1)

unpack_and_check_candidate
rpc_assert ':release_handler.install_release(~c"0.2.0") |> IO.inspect(label: "upgrade")' 'upgrade: {:ok, ~c"0.1.0"'
rpc_assert 'OpenAgents.ReleaseState.snapshot() |> IO.inspect(label: "state")' 'schema_version: 2'
rpc_assert 'OpenAgents.ReleaseState.snapshot() |> IO.inspect(label: "state")' 'retained-through-relup'
rpc_assert 'OpenAgents.ReleaseState |> Process.whereis() |> :erlang.pid_to_list() |> IO.puts()' "$state_pid"
rpc_assert ':release_handler.make_permanent(~c"0.2.0") |> IO.inspect(label: "commit")' 'commit: :ok'

rpc_assert ':release_handler.install_release(~c"0.1.0") |> IO.inspect(label: "downgrade")' 'downgrade: {:ok'
rpc_assert 'OpenAgents.ReleaseState.snapshot() |> IO.inspect(label: "state")' 'schema_version: 1'
rpc_assert 'OpenAgents.ReleaseState.snapshot() |> IO.inspect(label: "state")' 'retained-through-relup'
rpc_assert 'OpenAgents.ReleaseState |> Process.whereis() |> :erlang.pid_to_list() |> IO.puts()' "$state_pid"
rpc_assert ':release_handler.make_permanent(~c"0.1.0") |> IO.inspect(label: "commit")' 'commit: :ok'

rpc_assert ':release_handler.install_release(~c"0.2.0") |> IO.inspect(label: "reupgrade")' 'reupgrade: {:ok'
rpc_assert 'OpenAgents.ReleaseState.snapshot() |> IO.inspect(label: "state")' 'schema_version: 2'
rpc_assert 'OpenAgents.ReleaseState.snapshot() |> IO.inspect(label: "state")' 'retained-through-relup'
rpc_assert 'OpenAgents.ReleaseState |> Process.whereis() |> :erlang.pid_to_list() |> IO.puts()' "$state_pid"
rpc_assert ':release_handler.make_permanent(~c"0.2.0") |> IO.inspect(label: "commit")' 'commit: :ok'

echo "Relup version-chain proof passed"
