defmodule OpenAgents.Test.RollingFleet do
  @moduledoc """
  A three-node fleet whose readiness is decided by real boot convergence.

  Each simulated node carries one image identity. Every readiness answer this
  provider gives the rolling coordinator comes from
  `OpenAgents.Forge.BootConverge.classify/2` against the durable Forge target
  rows, which is the same rule `/healthz` uses to decide whether the load
  balancer keeps a node in rotation. The provider records a health sample on
  every callback so a test can prove what the fleet looked like throughout the
  roll rather than only at its end.
  """

  @behaviour OpenAgents.Forge.RollingProvider

  use Agent

  alias OpenAgents.Forge.BootConverge

  def start_link(initial) do
    Agent.start_link(
      fn ->
        Map.merge(
          %{events: [], health: [], removed: MapSet.new(), rolled_back: MapSet.new()},
          initial
        )
      end,
      name: __MODULE__
    )
  end

  @doc "Every provider interaction, oldest first."
  def events, do: Agent.get(__MODULE__, &Enum.reverse(&1.events))

  @doc "Every fleet health sample taken during the roll, oldest first."
  def health, do: Agent.get(__MODULE__, &Enum.reverse(&1.health))

  @doc "The image identity each node currently runs."
  def identities, do: Agent.get(__MODULE__, & &1.identities)

  @doc "Replace one node's image identity out of band."
  def put_identity(node, identity) do
    Agent.update(__MODULE__, fn state ->
      %{state | identities: Map.put(state.identities, node, identity)}
    end)
  end

  @doc "Stop failing the node that was failing."
  def clear_failure do
    Agent.update(__MODULE__, fn state ->
      %{state | fail_node: nil, rolled_back: MapSet.new()}
    end)
  end

  @impl true
  def members, do: Agent.get(__MODULE__, & &1.nodes)

  @impl true
  def remove_readiness(node, _context) do
    update(fn state -> %{state | removed: MapSet.put(state.removed, node)} end)
    record({:remove_readiness, node})
  end

  @impl true
  def restore_readiness(node, _context) do
    update(fn state -> %{state | removed: MapSet.delete(state.removed, node)} end)
    record({:restore_readiness, node})
  end

  @impl true
  def drain(node, _context) do
    record({:drain, node})
    {:ok, 0}
  end

  @impl true
  def capacity(nodes, _context) do
    record({:capacity, nodes})

    Agent.get(__MODULE__, fn state ->
      ready = Enum.count(nodes, &serving?(state, &1))
      {:ok, %{ready: ready, quorum: ready * 2 > length(state.nodes)}}
    end)
  end

  @impl true
  def replace(node, digest, context) do
    update(fn state ->
      %{
        state
        | identities: Map.put(state.identities, node, %{sha: context.sha, image_digest: digest}),
          removed: MapSet.delete(state.removed, node)
      }
    end)

    record({:replace, node, digest})
  end

  @impl true
  def rollback(node, digest, context) do
    update(fn state ->
      %{
        state
        | identities:
            Map.put(state.identities, node, %{
              sha: context.previous_sha,
              image_digest: digest
            }),
          removed: MapSet.delete(state.removed, node),
          rolled_back: MapSet.put(state.rolled_back, node)
      }
    end)

    record({:rollback, node, digest})
  end

  @impl true
  def status(node, _context) do
    record({:status, node})

    Agent.get(__MODULE__, fn state ->
      identity = Map.fetch!(state.identities, node)
      failed? = state.fail_node == node and not MapSet.member?(state.rolled_back, node)
      admitted? = admitted?(state, node)

      {:ok,
       %{
         member: not failed?,
         ready: admitted? and not failed?,
         boot_converged: admitted? and not failed?,
         database_ready: true,
         sha: identity.sha,
         image_digest: identity.image_digest
       }}
    end)
  end

  # Boot convergence decides admission from the durable Forge target rows, so
  # this is the same verdict `/healthz` would return on that node.
  defp admitted?(state, node) do
    BootConverge.classify(state.repo, Map.fetch!(state.identities, node)) != :divergent
  end

  defp serving?(state, node) do
    admitted?(state, node) and not MapSet.member?(state.removed, node)
  end

  defp record(event) do
    sample =
      Agent.get(__MODULE__, fn state ->
        %{
          admitted: Enum.count(state.nodes, &admitted?(state, &1)),
          serving: Enum.count(state.nodes, &serving?(state, &1))
        }
      end)

    update(fn state ->
      %{state | events: [event | state.events], health: [sample | state.health]}
    end)

    :ok
  end

  defp update(function), do: Agent.update(__MODULE__, function)
end
