defmodule OpenAgents.Test.RollingProvider do
  @moduledoc false

  @behaviour OpenAgents.Forge.RollingProvider

  use Agent

  def start_link(initial) do
    Agent.start_link(fn -> initial end, name: __MODULE__)
  end

  def events, do: Agent.get(__MODULE__, &Enum.reverse(&1.events))

  @impl true
  def members, do: Agent.get(__MODULE__, & &1.members)

  @impl true
  def remove_readiness(node, _context) do
    event({:remove_readiness, node})
    :ok
  end

  @impl true
  def restore_readiness(node, _context) do
    event({:restore_readiness, node})
    :ok
  end

  @impl true
  def drain(node, _context) do
    event({:drain, node})
    {:ok, 0}
  end

  @impl true
  def capacity(nodes, _context) do
    event({:capacity, nodes})

    Agent.get(__MODULE__, fn state ->
      Map.get(state, :capacity) || {:ok, %{ready: length(nodes), quorum: true}}
    end)
  end

  @impl true
  def replace(node, digest, _context) do
    event({:replace, node, digest})

    Agent.update(__MODULE__, fn state ->
      %{state | digests: Map.put(state.digests, node, digest)}
    end)

    :ok
  end

  @impl true
  def status(node, context) do
    event({:status, node})

    Agent.get(__MODULE__, fn state ->
      rolled_back? = MapSet.member?(state.rolled_back, node)
      failed? = state.fail_node == node and not rolled_back?
      digest = Map.fetch!(state.digests, node)

      {:ok,
       %{
         member: not failed?,
         ready: not failed?,
         boot_converged: not failed?,
         database_ready: not failed?,
         sha: if(rolled_back?, do: state.previous_sha, else: context.sha),
         image_digest: digest
       }}
    end)
  end

  @impl true
  def rollback(node, digest, _context) do
    event({:rollback, node, digest})

    Agent.update(__MODULE__, fn state ->
      %{
        state
        | digests: Map.put(state.digests, node, digest),
          rolled_back: MapSet.put(state.rolled_back, node)
      }
    end)

    :ok
  end

  defp event(value) do
    Agent.update(__MODULE__, fn state -> %{state | events: [value | state.events]} end)
  end
end
