defmodule OpenAgents.Cluster.RaBootstrapTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Cluster.RaBootstrap

  test "keeps a healthy local member unchanged" do
    assert :healthy =
             RaBootstrap.convergence_action(
               :node1@host,
               [:node1@host, :node2@host],
               [:node1@host, :node2@host],
               [:node1@host, :node2@host],
               3
             )
  end

  test "restarts a phantom local member from the peer membership" do
    peer_members = [:node1@host, :node2@host, :node3@host]

    assert {:restart_local, ^peer_members} =
             RaBootstrap.convergence_action(
               :node1@host,
               peer_members,
               [],
               peer_members,
               3
             )
  end

  test "joins through a reachable member of an existing cluster" do
    assert {:join, :node2@host} =
             RaBootstrap.convergence_action(
               :node1@host,
               [:node1@host, :node2@host],
               [],
               [:node3@host, :node2@host],
               3
             )
  end

  test "forms only when the local node is coordinator and a majority is present" do
    connected = [:node1@host, :node2@host]

    assert {:form, ^connected} =
             RaBootstrap.convergence_action(:node1@host, connected, [], [], 3)

    assert :wait =
             RaBootstrap.convergence_action(:node2@host, connected, [], [], 3)

    assert :wait =
             RaBootstrap.convergence_action(:node1@host, [:node1@host], [], [], 3)
  end
end
