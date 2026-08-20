defmodule OpenAgents.Cluster.Drain do
  @moduledoc """
  Graceful node drain for rolling deploys (M3).

  Before a node is destroyed and replaced on a new release/ERTS, `drain/0`:

  1. **Leaves the Raft cluster** cleanly (`OpenAgents.Cluster.Ra.remove_member/1` on
     self), so the session registry recomputes quorum over the *remaining*
     members instead of counting a node that is about to vanish. Ra transfers
     leadership first if this node holds it.
  2. Reports how many Work singletons still live here, so the deploy driver can
     wait until this node owns nothing before killing it — its singletons
     relocate to survivors via the M1 Horde handoff.

  Rolling one node at a time keeps both the BEAM cluster and the Raft cluster
  above quorum throughout, so the cluster never drops — retiring the whole
  "interrupted on deploy" failure class for BEAM-durable sessions. (External
  legs — controller/ACP, voice — re-attach via M2.)
  """

  require Logger

  alias OpenAgents.Cluster.Ra

  @doc """
  Prepare this node to be replaced by a rolling deploy: report residual Work
  ownership so the driver can proceed. Returns `{:ok, local_singletons}`.

  For a rolling **replacement** (the node keeps its name and comes back), we do
  NOT leave the Raft cluster: the node's Ra data lives on the host disk and
  survives the reset, so on reboot it restarts its Raft server from disk and
  rejoins cleanly (`RaBootstrap` phantom recovery), while membership stays
  stable and quorum is only ever down by one. Its in-flight Work singletons
  relocate to survivors via the M1 Horde handoff when the node resets.

  For a permanent scale-down (a node that will not return), call `leave_ra/0`
  explicitly to remove it from the Raft configuration.
  """
  def drain do
    {:ok, local_singleton_count()}
  end

  @doc "Remove this node from the Raft cluster if it is a member (permanent scale-down). Idempotent."
  def leave_ra do
    members = Ra.members()

    if members != [] and node() in members do
      case Ra.remove_member(node()) do
        {:ok, _, _} ->
          Logger.info("drain: left Raft cluster (#{node()})")
          :ok

        other ->
          Logger.warning("drain_leave_ra_refused code=#{OpenAgents.OperationalLog.code(other)}")
          :ok
      end
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("drain_leave_ra_failed code=#{OpenAgents.OperationalLog.code(error)}")
      :ok
  end

  @doc "How many Work singletons are currently running on this node."
  def local_singleton_count do
    OpenAgents.HordeSupervisor
    |> Horde.DynamicSupervisor.which_children()
    |> Enum.count(fn {_id, pid, _type, _mods} -> is_pid(pid) and node(pid) == node() end)
  rescue
    _ -> 0
  end
end
