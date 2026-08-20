defmodule OpenAgents.Cluster.CodeChangeTest do
  @moduledoc """
  Proves the M4 hot-upgrade mechanism: an OTP `:sys.change_code` migrates a
  live process's state from an old shape to the current one **in place** — same
  pid, no restart, state carried across. This is what lets a relup swap code
  under running turns/jobs/voice instead of dropping them.
  """
  use ExUnit.Case, async: true

  alias OpenAgents.Test.UpgradableCounter, as: Counter

  test "code_change/3 migrates old (v1) state to the new struct without restarting the process" do
    {:ok, pid} = Counter.start_link()

    # Simulate a process that was started under the OLD release: force its state
    # to the v1 shape (a bare map with :count, no :label / :version).
    :sys.replace_state(pid, fn _new -> %{count: 7} end)
    assert :sys.get_state(pid) == %{count: 7}

    # Suspend → change_code (runs code_change("1", state, [])) → resume, exactly
    # as a relup's {update, Mod, {advanced, _}} instruction does.
    :ok = :sys.suspend(pid)
    :ok = :sys.change_code(pid, Counter, "1", [])
    :ok = :sys.resume(pid)

    # Same process, migrated state: the v1 count survived and the v2 fields were
    # filled in — no drop, no restart.
    assert Process.alive?(pid)
    migrated = :sys.get_state(pid)
    assert migrated == %Counter{version: 2, count: 7, label: "default"}
    assert GenServer.call(pid, :get) == migrated

    GenServer.stop(pid)
  end

  test "code_change/3 is idempotent for a state already at the current version" do
    state = %Counter{version: 2, count: 3, label: "x"}
    assert Counter.code_change("2", state, []) == {:ok, state}
  end
end
