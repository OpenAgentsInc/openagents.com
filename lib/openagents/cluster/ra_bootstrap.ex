defmodule OpenAgents.Cluster.RaBootstrap do
  @moduledoc """
  Brings up the Ra (Raft) session-registry cluster on the fleet, and keeps this
  node a member as the cluster changes.

  Opt-in via `config :openagents, :ra_enabled` (the fleet sets it; single-node
  Cloud Run leaves it off, so Raft never runs there). Once enabled:

  1. Start the Ra system locally (`Ra.start_in/1`) so this node can host a
     Raft server.
  2. Periodically, and on every `nodeup`/`nodedown`, converge membership:
     - if no cluster is formed yet, the **coordinator** (the lowest-named
       connected node) forms it across the connected quorum once a majority of
       the expected fleet is present;
     - a node that is up but not yet a member **adds itself** to the formed
       cluster.

  Forming from the coordinator + late self-joins avoids a split during rolling
  starts. Postgres remains the durable ledger, so a botched formation is never a
  data-loss event — at worst the `OpenAgents.Cluster.Sessions` facade stays in its
  safe no-op mode until the cluster is healthy.
  """

  use GenServer

  require Logger

  alias OpenAgents.Cluster.Ra

  @interval 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    data_dir = Application.get_env(:openagents, :ra_data_dir, "/tmp/sarah_ra")
    expected = Application.get_env(:openagents, :ra_expected_size, 3)

    Ra.start_in(data_dir)
    :ok = :net_kernel.monitor_nodes(true, node_type: :visible)
    send(self(), :converge)
    schedule()

    {:ok, %{expected: expected}}
  end

  @impl true
  def handle_info(:converge, state) do
    _ = converge(state.expected)
    {:noreply, state}
  end

  def handle_info({node_event, _node}, state) when node_event in [:nodeup, :nodedown] do
    _ = converge(state.expected)
    {:noreply, state}
  end

  def handle_info({node_event, _node, _info}, state)
      when node_event in [:nodeup, :nodedown] do
    _ = converge(state.expected)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    _ = converge(state.expected)
    schedule()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── convergence ─────────────────────────────────────────────────────────────

  defp converge(expected) do
    connected = [node() | Node.list()]
    # Our own local server's view (empty if it is not running here).
    local_members = safe_members(node())
    # The cluster's member set as seen by a peer (survives our local server
    # being down — the phantom-member case after an ungraceful restart).
    peer_members = discover_members(connected -- [node()])
    members = if local_members != [], do: local_members, else: peer_members

    cond do
      # Healthy: our local server is up and we are a member.
      node() in local_members ->
        :ok

      # Phantom: peers still list us as a member but our local Raft server is
      # not running (ungraceful restart lost the tmpfs data dir). Restart it so
      # it rejoins and catches up, instead of sitting as a dead config entry.
      node() in peer_members ->
        _ = Ra.ensure_local_server(peer_members)
        Logger.info("ra_bootstrap: restarted phantom local server (#{node()})")

      # Cluster is formed elsewhere but we are not in it yet: join through an
      # existing member (add_member + start our local server).
      members != [] ->
        via = Enum.find(members, &(&1 in connected)) || hd(members)

        case Ra.join(via) do
          {:ok, _, _} -> Logger.info("ra_bootstrap: joined cluster via #{via} (#{node()})")
          :ok -> Logger.info("ra_bootstrap: joined cluster via #{via} (#{node()})")
          _other -> :ok
        end

      # No cluster yet. The coordinator forms it once a majority is present.
      coordinator?(connected) and majority?(length(connected), expected) ->
        case Ra.start_cluster(connected) do
          {:ok, started} ->
            Logger.info("ra_bootstrap: formed cluster across #{inspect(started)}")

          _other ->
            :ok
        end

      true ->
        :ok
    end
  rescue
    error ->
      Logger.warning("ra_bootstrap: converge error #{inspect(error)}")
      :ok
  end

  # We are the coordinator iff we are the lowest-named connected node — a stable,
  # coordinator-free way to pick exactly one former.
  defp coordinator?(connected), do: node() == Enum.min(connected)

  defp majority?(present, expected), do: present * 2 > expected

  # The member set as seen by any connected node whose Raft server answers.
  defp discover_members(connected) do
    Enum.find_value(connected, [], fn n ->
      case safe_members(n) do
        [] -> nil
        members -> members
      end
    end)
  end

  defp safe_members(node) do
    Ra.members(node)
  rescue
    _ -> []
  end

  defp schedule, do: Process.send_after(self(), :tick, @interval)
end
