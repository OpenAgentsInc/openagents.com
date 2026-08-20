defmodule OpenAgents.Test.HordePeer do
  @moduledoc """
  Starts the app's Horde topology on a `:peer` test node under a persistent
  keeper process.

  A naive `:erpc.call(node, Horde.Registry, :start_link, ...)` links the Horde
  process to the transient erpc handler, which exits the moment the call
  returns and takes Horde down with it. The keeper here is a long-lived process
  that owns (is linked to) both components and sleeps forever, so they live as
  long as the peer node does — and die with it when the node is stopped, which
  is exactly the node-loss signal the handoff test needs.
  """

  @registry OpenAgents.HordeRegistry
  @supervisor OpenAgents.HordeSupervisor

  @doc "Start `OpenAgents.HordeRegistry` + `OpenAgents.HordeSupervisor` on this node. Returns the keeper pid."
  def start! do
    parent = self()

    keeper =
      spawn(fn ->
        {:ok, _reg} =
          OpenAgents.Cluster.Registry.start_link(
            name: @registry,
            keys: :unique,
            members: :auto,
            delta_crdt_options: [sync_interval: 150]
          )

        {:ok, _sup} =
          OpenAgents.Cluster.DynamicSupervisor.start_link(
            name: @supervisor,
            strategy: :one_for_one,
            members: :auto,
            process_redistribution: :passive,
            delta_crdt_options: [sync_interval: 150]
          )

        send(parent, {:horde_started, self()})
        Process.sleep(:infinity)
      end)

    receive do
      {:horde_started, ^keeper} -> {:ok, keeper}
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc """
  A Horde child spec for a singleton stub Agent keyed by `key`.

  The Agent's value function is a *named* function in this module (which is
  compiled to ebin and loadable on peers), not an anonymous function in a test
  module (which is not) — so Horde can start the singleton on whichever node it
  routes to, including a peer.
  """
  def singleton_spec(key) do
    via = {:via, Horde.Registry, {@registry, key}}

    %{
      id: key,
      start: {Agent, :start_link, [&__MODULE__.value/0, [name: via]]},
      restart: :transient
    }
  end

  @doc false
  def value, do: :handoff_singleton
end
