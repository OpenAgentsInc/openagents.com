defmodule OpenAgents.Cluster.Ra do
  @moduledoc """
  Bootstraps and fronts the Ra (Raft) cluster that holds Sarah's authoritative
  live-session registry (`OpenAgents.Cluster.SessionRegistry`).

  Ownership + the generation fence are committed through Raft, so they are
  strongly consistent and survive a minority of nodes failing (quorum). Ra holds
  only the *in-flight* slice; Postgres remains the durable ledger and rehydrates
  Ra on a full-cluster cold start.

  Startup is opt-in and single-node-safe: `start_in/1` sets Ra's data dir and
  starts the default system; the cluster itself is only formed when
  `OpenAgents.Cluster` is actually distributed (the fleet), so the single-instance
  Cloud Run runtime never runs Raft.
  """

  alias OpenAgents.Cluster.SessionRegistry

  @system :default
  @cluster :openagents_sessions
  @machine {:module, SessionRegistry, %{}}
  @timeout 5_000

  @doc "The Ra server id for a node: `{:openagents_sessions, node}`."
  def server_id(node \\ node()), do: {@cluster, node}

  @doc """
  Start the Ra system on this node with a data directory. Idempotent enough to
  call at boot; returns `:ok` whether or not the system was already up.
  """
  def start_in(data_dir) do
    _ = :ra.start_in(String.to_charlist(data_dir))
    :ok
  end

  @doc """
  Form (or join) the Raft cluster across `nodes`.

  `:ra.start_cluster/4` is idempotent for an already-formed cluster and starts a
  server on every listed node, electing one leader. Call it from one node once a
  quorum of the fleet is connected.
  """
  def start_cluster(nodes) when is_list(nodes) do
    server_ids = Enum.map(nodes, &server_id/1)

    case :ra.start_cluster(@system, Atom.to_string(@cluster), @machine, server_ids) do
      {:ok, started, _not_started} -> {:ok, started}
      {:error, :cluster_not_formed} = err -> err
      other -> other
    end
  end

  @doc """
  Join this node to an existing cluster, routing the config change through a
  server that is already a member (`via_node`).

  Two steps, both required: add our server id to the cluster configuration on an
  existing member, then start our local Raft server so it actually joins as a
  follower and catches up. Idempotent-friendly: an `already_member` add still
  proceeds to (re)start the local server.
  """
  def join(via_node) do
    member = server_id(via_node)
    new = server_id()

    case :ra.add_member(member, new) do
      {:ok, _, _} -> start_local_server([member])
      {:error, :already_member} -> start_local_server([member])
      other -> other
    end
  end

  defp start_local_server(known_members) do
    :ra.start_server(@system, Atom.to_string(@cluster), server_id(), @machine, known_members)
  end

  @doc """
  Ensure this node's Raft server is running when it is already in the cluster
  configuration — the "phantom member" case after an ungraceful restart that
  lost the local data dir (the fleet keeps Ra on tmpfs). Tries a plain restart
  from disk first (graceful case), then falls back to starting a fresh server
  that rejoins as a follower and catches up from the leader.
  """
  def ensure_local_server(known_member_nodes) do
    case :ra.restart_server(@system, server_id()) do
      :ok ->
        :ok

      _needs_fresh_start ->
        members = Enum.map(known_member_nodes, &server_id/1)

        case start_local_server(members) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          other -> other
        end
    end
  end

  @doc "Remove a node from the cluster (e.g. a permanently-gone node)."
  def remove_member(node) do
    :ra.remove_member(server_id(), server_id(node))
  end

  @doc """
  The current Raft member nodes as seen by `node`'s server, or `[]` if that
  server is not up / not a member. Defaults to the local server.
  """
  def members(node \\ node()) do
    case :ra.members(server_id(node)) do
      {:ok, servers, _leader} -> Enum.map(servers, fn {_name, n} -> n end)
      _ -> []
    end
  end

  # ── session-registry client (fenced) ───────────────────────────────────────

  @doc "Claim/adopt ownership of a session; returns `{:ok, generation}`."
  def claim(id, kind), do: command({:claim, id, kind, node()})

  @doc "Commit a bounded checkpoint under the held generation (fenced)."
  def checkpoint(id, generation, data), do: command({:checkpoint, id, generation, data})

  @doc "Mark a session terminal under the held generation (fenced)."
  def finish(id, generation), do: command({:finish, id, generation})

  @doc "Release a session entry under the held generation (fenced)."
  def release(id, generation), do: command({:release, id, generation})

  @doc "Linearizable read of a session entry (or nil)."
  def lookup(id) do
    case :ra.consistent_query(server_id(), SessionRegistry.lookup(id), @timeout) do
      {:ok, result, _leader} -> {:ok, result}
      other -> {:error, other}
    end
  end

  @doc "Linearizable list of session ids a node currently owns."
  def owned_by(node) do
    case :ra.consistent_query(server_id(), SessionRegistry.owned_by(node), @timeout) do
      {:ok, result, _leader} -> {:ok, result}
      other -> {:error, other}
    end
  end

  # ── internal ───────────────────────────────────────────────────────────────

  # process_command auto-redirects to the current leader; we target the local
  # server so any live node can issue commands.
  defp command(cmd) do
    case :ra.process_command(server_id(), cmd, @timeout) do
      {:ok, reply, _leader} -> reply
      {:error, reason} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
    end
  end
end
