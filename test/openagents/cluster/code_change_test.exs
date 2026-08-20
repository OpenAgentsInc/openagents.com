defmodule OpenAgents.Cluster.CodeChangeTest do
  @moduledoc """
  Proves the M4 hot-upgrade mechanism: an OTP `:sys.change_code` migrates a
  live process's state from an old shape to the current one **in place** — same
  pid, no restart, state carried across. This is what lets a relup swap code
  under running turns/jobs/voice instead of dropping them.
  """
  use ExUnit.Case, async: true

  alias OpenAgents.ReleaseState
  alias OpenAgents.ReleaseState.State

  test "upgrade, downgrade, and re-upgrade preserve PID and observations" do
    pid = start_supervised!({ReleaseState, name: nil})
    :ok = ReleaseState.observe("retained", pid)

    :sys.replace_state(pid, fn %State{} = state ->
      %State{state | schema_version: 1, integrity: nil}
    end)

    :ok = :sys.suspend(pid)
    :ok = :sys.change_code(pid, ReleaseState, ~c"0.1.0", [])
    :ok = :sys.resume(pid)

    assert %State{schema_version: 2, observations: ["retained"], integrity: integrity} =
             ReleaseState.snapshot(pid)

    assert is_binary(integrity)

    :ok = :sys.suspend(pid)
    :ok = :sys.change_code(pid, ReleaseState, {:down, ~c"0.2.0"}, [])
    :ok = :sys.resume(pid)

    assert %State{schema_version: 1, observations: ["retained"], integrity: nil} =
             ReleaseState.snapshot(pid)

    :ok = :sys.suspend(pid)
    :ok = :sys.change_code(pid, ReleaseState, ~c"0.1.0", [])
    :ok = :sys.resume(pid)

    assert %State{schema_version: 2, observations: ["retained"]} = ReleaseState.snapshot(pid)
    assert %State{} = :sys.get_state(pid)
  end
end
