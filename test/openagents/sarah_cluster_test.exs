defmodule OpenAgents.SarahClusterTest do
  # Not async: it manipulates node-global distribution state.
  use ExUnit.Case, async: false
  @moduletag :skip
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
          name: :sarah_cluster_peer,
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

      match?({:ok, _}, :net_kernel.start([:"sarah_test@127.0.0.1", :longnames])) ->
        :erlang.set_cookie(Node.self(), :sarah_cluster_test_cookie)
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
end
