defmodule OpenAgents.Cluster.BasicTest do
  # Not async: it manipulates node-global distribution state.
  use ExUnit.Case, async: false
  alias OpenAgents.Cluster

  describe "single-node (undistributed or one member)" do
    test "reports one member and holds quorum for a single-node deployment" do
      assert Cluster.size() >= 1
      assert Cluster.quorum?(1)
      assert is_map(Cluster.snapshot())
      assert Cluster.snapshot()["size"] == Cluster.size()
    end
  end

  describe "real two-node cluster" do
    @describetag :cluster

    setup do
      case ensure_distributed() do
        :ok ->
          :ok

        :unavailable ->
          flunk("distribution unavailable — start epmd (`epmd -daemon`) to run :cluster tests")
      end
    end

    test "a peer node joins, is counted, gives quorum for 3, and its loss is detected" do
      cookie = :erlang.get_cookie()

      {:ok, peer, node} =
        :peer.start_link(%{
          name: unique_peer_name("openagents_cluster_peer"),
          host: ~c"127.0.0.1",
          args: [~c"-setcookie", Atom.to_charlist(cookie)]
        })

      # The peer joins the distribution mesh.
      assert node in Cluster.peers()
      assert Cluster.size() >= 2
      # With 2 live members, a 3-node cluster still has majority quorum.
      assert Cluster.quorum?(3)
      assert to_string(node) in Cluster.snapshot()["members"]

      # A node leaving is detected — membership shrinks back.
      :peer.stop(peer)
      assert eventually(fn -> node not in Cluster.peers() end)
    end
  end

  # Ensure this node is distributed so peers can join; return :unavailable when
  # the environment cannot start distribution (no epmd), so the test skips
  # rather than failing.
  defp ensure_distributed do
    cond do
      Node.self() != :nonode@nohost ->
        :ok

      # Unique per run: a fixed name that a crashed run left registered with
      # epmd makes net_kernel refuse to start ever after. OpenAgents-named now
      # that this is not Sarah's BEAM.
      match?({:ok, _}, :net_kernel.start([unique_test_node(), :longnames])) ->
        :erlang.set_cookie(Node.self(), :openagents_cluster_test_cookie)
        :ok

      true ->
        :unavailable
    end
  end

  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end

  defp unique_test_node do
    :erlang.list_to_atom(~c"openagents_test_#{:erlang.unique_integer([:positive])}@127.0.0.1")
  end

  defp unique_peer_name(base) do
    :erlang.list_to_atom(~c"#{base}_#{:erlang.unique_integer([:positive])}")
  end
end
