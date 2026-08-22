defmodule OpenAgents.Cluster.CodeChangeTest do
  @moduledoc """
  Proves the M4 hot-upgrade mechanism: an OTP `:sys.change_code` migrates a
  live process's state from an old shape to the current one **in place** — same
  pid, no restart, state carried across. This is what lets a relup swap code
  under running turns/jobs/voice instead of dropping them.

  The target schema is the installing release's, not a function of direction.
  A downgrade runs `code_change/3` in the new module before the old code loads,
  so the appup names the schema explicitly and this module refuses to guess.
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

    change_code(pid, ~c"0.1.0", schema_version: 2)

    assert %State{schema_version: 2, observations: ["retained"], integrity: integrity} =
             ReleaseState.snapshot(pid)

    assert is_binary(integrity)

    change_code(pid, {:down, ~c"0.2.0"}, schema_version: 1)

    assert %State{schema_version: 1, observations: ["retained"], integrity: nil} =
             ReleaseState.snapshot(pid)

    change_code(pid, ~c"0.1.0", schema_version: 2)

    assert %State{schema_version: 2, observations: ["retained"]} = ReleaseState.snapshot(pid)
    assert %State{} = :sys.get_state(pid)
  end

  test "a same-schema pair keeps its schema through a downgrade" do
    pid = start_supervised!({ReleaseState, name: nil})
    :ok = ReleaseState.observe("retained", pid)

    change_code(pid, ~c"0.2.0", schema_version: 2)
    change_code(pid, {:down, ~c"0.3.0"}, schema_version: 2)

    assert %State{schema_version: 2, observations: ["retained"], integrity: integrity} =
             ReleaseState.snapshot(pid)

    assert is_binary(integrity)
  end

  test "a downgrade without an explicit target schema refuses" do
    pid = start_supervised!({ReleaseState, name: nil})
    :ok = :sys.suspend(pid)

    refused = :sys.change_code(pid, ReleaseState, {:down, ~c"0.3.0"}, [])
    :ok = :sys.resume(pid)

    assert {:error, {:error, :missing_downgrade_schema_version}} = refused
  end

  defp change_code(pid, version, extra) do
    :ok = :sys.suspend(pid)
    :ok = :sys.change_code(pid, ReleaseState, version, extra)
    :ok = :sys.resume(pid)
  end
end
