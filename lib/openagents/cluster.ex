defmodule OpenAgents.Cluster do
  @moduledoc """
  Cluster membership and quorum for the distributed OpenAgents runtime.

  The runtime is single-node-safe: with no distribution and no peers this reports
  a one-member cluster and every predicate degrades sensibly, so the same code
  runs unchanged on a single Cloud Run instance and on the clustered fleet. The
  clustering itself is formed by `DNSCluster` (already wired) once
  `DNS_CLUSTER_QUERY` resolves to the peers; this module is the read/quorum
  surface the handoff and upgrade machinery builds on.
  """

  @erpc_timeout_ms 5_000

  @doc "The currently expected relup marker for live nodes."
  def relup_marker, do: "v2-relup-live"

  @doc "All cluster members, including this node."
  @spec members() :: [node()]
  def members, do: [Node.self() | Node.list()]

  @doc "Just the connected peers (excludes this node)."
  @spec peers() :: [node()]
  def peers, do: Node.list()

  @doc "Number of members in the cluster (>= 1)."
  @spec size() :: pos_integer()
  def size, do: length(members())

  @doc "Whether this node is running in distributed mode at all."
  @spec distributed?() :: boolean()
  def distributed?, do: Node.self() != :nonode@nohost

  @doc """
  Whether the cluster holds a majority quorum for `expected` total nodes.

  Quorum is the guard that keeps a partitioned minority from serving owned
  singletons. A single-node deployment (`expected == 1`) always has quorum.
  """
  @spec quorum?(pos_integer()) :: boolean()
  def quorum?(expected) when is_integer(expected) and expected >= 1 do
    size() * 2 > expected
  end

  @doc """
  A bounded, serializable snapshot of cluster state for observability/receipts.
  """
  @spec snapshot() :: map()
  def snapshot do
    %{
      "schema" => "openagents.cluster_state.v1",
      "node" => to_string(Node.self()),
      "distributed" => distributed?(),
      "members" => Enum.map(members(), &to_string/1),
      "size" => size()
    }
  end

  @doc """
  A bounded health report for this node. Liveness means the VM and BEAM are
  running; readiness is a runtime assertion that will be driven by boot
  convergence and application health checks in later phases.
  """
  @spec local_report() :: map()
  def local_report do
    %{
      "schema" => "openagents.cluster_health.v1",
      "node" => to_string(Node.self()),
      "version" => to_string(Application.spec(:openagents, :vsn) || "unknown"),
      "revision" => OpenAgents.BuildInfo.revision(),
      "boot_converged" => nil,
      "uptime_ms" => uptime_ms(),
      "live" => true,
      "ready" => true
    }
  end

  @doc """
  Collect a bounded health report across the cluster using `:erpc.multicall`.
  Returns the local report plus peer reports. Missing or divergent peers are
  reported in `missing` so the status surface can show them without blocking.
  """
  @spec health_report() :: map()
  def health_report do
    local = local_report()
    peer_nodes = peers()
    peer_reports = peer_reports(peer_nodes)
    revisions = [local["revision"] | Enum.map(Map.values(peer_reports), & &1["revision"])]
    all_peers_reported? = map_size(peer_reports) == length(peer_nodes)
    consistent? = all_peers_reported? and length(Enum.uniq(revisions)) == 1

    %{
      "schema" => "openagents.cluster_health_report.v1",
      "node" => to_string(Node.self()),
      "consistent" => consistent?,
      "local" => local,
      "peers" => peer_reports,
      "missing" => Enum.map(peer_nodes, &to_string/1) -- Map.keys(peer_reports)
    }
  end

  @doc "Returns the list of connected peers whose revision differs from this node."
  @spec divergent() :: [node()]
  def divergent do
    local_revision = OpenAgents.BuildInfo.revision()

    peers()
    |> peer_reports()
    |> Enum.filter(fn {_name, report} -> report["revision"] != local_revision end)
    |> Enum.map(fn {name, _report} -> name end)
    |> Enum.map(&String.to_atom/1)
  end

  @doc "Returns true when every connected peer reports the same revision."
  @spec consistent?() :: boolean()
  def consistent?, do: divergent() == []

  defp peer_reports([]), do: %{}

  defp peer_reports(peer_nodes) do
    results =
      :erpc.multicall(peer_nodes, __MODULE__, :local_report, [], @erpc_timeout_ms)

    results
    |> Enum.zip(peer_nodes)
    |> Enum.reduce(%{}, fn
      {{:ok, report}, _node}, acc when is_map(report) ->
        Map.put(acc, to_string(report["node"]), report)

      {_result, _node}, acc ->
        acc
    end)
  end

  defp uptime_ms do
    {wall, _} = :erlang.statistics(:wall_clock)
    wall
  end
end
