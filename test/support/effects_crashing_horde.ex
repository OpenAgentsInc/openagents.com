defmodule OpenAgents.Effects.WorkLaunchTest.CrashingHorde do
  @moduledoc """
  A stand-in for `OpenAgents.HordeSupervisor` that refuses to start children.

  During `OpenAgents.Work.start_job/1`, the job row and the launch effect are
  committed in one transaction, and then the worker is asked for inline. This
  module lets the transaction commit and the broadcast run, then reports a
  placement failure, so the effect is left pending exactly as a real crash in
  that gap would.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options) do
    GenServer.start_link(__MODULE__, [], name: OpenAgents.HordeSupervisor)
  end

  @impl true
  def init(_init_arg) do
    {:ok, nil}
  end

  @impl true
  def handle_call({:start_child, _child_spec}, _from, state) do
    {:reply, {:error, :worker_start_failed}, state}
  end

  @impl true
  def handle_call(_request, _from, state) do
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_info(_message, state) do
    {:noreply, state}
  end
end
