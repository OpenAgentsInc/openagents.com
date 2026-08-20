defmodule OpenAgents.Test.UpgradableCounter do
  @moduledoc """
  A minimal GenServer that carries a **versioned struct state** and a real
  `code_change/3`, to exercise the M4 hot-upgrade mechanism (OTP
  `:sys.change_code`) in a test: an in-place code swap must migrate the live
  process's state from the old shape to the new one without restarting it.

  This is the discipline every stateful server in the system follows so a relup
  can `{update, Mod, {advanced, Extra}}` it (suspend → load → code_change →
  resume) instead of dropping the process on deploy.
  """
  use GenServer

  # v2 state: v1 was %{count: n} with no label; v2 adds :label and a version tag.
  defstruct version: 2, count: 0, label: "default"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, opts)

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  # Migrate an old (v1) state to the current (v2) struct. Idempotent for a state
  # already at v2. This is the whole point of the discipline: the exact function
  # a relup's advanced update runs against each live process.
  @impl true
  def code_change("1", %{count: count}, _extra) do
    {:ok, %__MODULE__{version: 2, count: count, label: "default"}}
  end

  def code_change(_old_vsn, %__MODULE__{} = state, _extra), do: {:ok, state}
end
