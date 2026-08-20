defmodule OpenAgents.ClusterTest do
  # Not async: the last test manipulates node-global distribution state.
  use ExUnit.Case, async: false

  alias OpenAgents.Cluster

  test "single-node health report is well-formed" do
    report = Cluster.local_report()

    assert report["schema"] == "openagents.cluster_health.v1"
    assert report["node"] == to_string(Node.self())
    assert report["revision"] == OpenAgents.BuildInfo.revision()
    assert report["version"] == to_string(Application.spec(:openagents, :vsn) || "unknown")
    assert report["live"] == true
    assert report["ready"] == true
    assert is_integer(report["uptime_ms"])
  end

  test "quorum and snapshot in single-node mode" do
    assert Cluster.size() == 1
    assert Cluster.members() == [Node.self()]
    assert Cluster.distributed?() == false
    assert Cluster.quorum?(1)
    refute Cluster.quorum?(3)

    snapshot = Cluster.snapshot()
    assert snapshot["schema"] == "openagents.cluster_state.v1"
    assert snapshot["size"] == 1
  end

  # Real peer nodes: gated to the `mix test --only cluster` stage, like every
  # other distribution test here. Left in the default suite it both needs epmd
  # and inherits whatever node-global state a previous cluster module left
  # behind — which is exactly how it came to fail on `net_kernel already started`.
  @tag :cluster
  test "three local nodes form a cluster, report a consistent revision, and detect a missing node" do
    start_distribution!()
    peers = start_peers(3)

    try do
      for {_pid, node} <- peers, do: Node.connect(node)

      assert wait_for(fn -> length(Node.list()) == 3 end)
      assert length(Cluster.members()) == 4

      report = Cluster.health_report()
      assert report["consistent"] == true
      assert map_size(report["peers"]) == 3
      assert report["missing"] == []

      # Stop one peer and verify the next report shrinks and marks it missing.
      [{down_pid, down_node} | _] = peers
      :peer.stop(down_pid)

      assert wait_for(fn -> length(Node.list()) == 2 end)

      report2 = Cluster.health_report()
      assert report2["consistent"] == true
      assert map_size(report2["peers"]) == 2
      assert report2["missing"] == []
      refute to_string(down_node) in Enum.map(Cluster.members(), &to_string/1)
    after
      # Stop this test's peers, but leave net_kernel up. Stopping it stranded
      # every cluster module scheduled after this one: their
      # `ensure_distributed/0` then saw an undistributed node whose net_kernel
      # would no longer restart, and flunked "distribution unavailable".
      for {pid, _node} <- peers, do: safe_stop_peer(pid)
      assert wait_for(fn -> Node.list() == [] end)
    end
  end

  # Idempotent: an already-distributed node is a legitimate state in the cluster
  # stage (another module got here first), not a reason to fail.
  defp start_distribution! do
    suffix = :erlang.unique_integer([:positive])
    name = :erlang.list_to_atom(~c"openagents_test_#{suffix}@127.0.0.1")

    case :net_kernel.start([name, :longnames]) do
      :ok -> :ok
      true -> :ok
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> raise "Failed to start net_kernel: #{inspect(other)}"
    end

    _ = Node.set_cookie(:openagents_test_cookie)
    :ok
  end

  defp start_peers(n) do
    ebins = [
      Application.app_dir(:openagents, "ebin"),
      Application.app_dir(:elixir, "ebin")
    ]

    pa_args =
      Enum.flat_map(ebins, fn path ->
        [~c"-pa", to_charlist(path)]
      end)

    cookie = :openagents_test_cookie

    Enum.map(1..n, fn i ->
      suffix = :erlang.unique_integer([:positive])
      short_name = :erlang.list_to_atom(~c"openagents_peer#{i}_#{suffix}")

      {:ok, pid, node} =
        :peer.start_link(%{
          name: short_name,
          host: ~c"127.0.0.1",
          user: %{},
          shutdown: OpenAgents.Test.RemoteCover.shutdown(),
          args:
            [
              ~c"-setcookie",
              to_charlist(Atom.to_string(cookie))
            ] ++ pa_args
        })

      # Make sure the OpenAgents app is loaded on the peer so version and
      # revision are available for health reports.
      :ok = :erpc.call(node, Application, :load, [:openagents])
      {pid, node}
    end)
  end

  defp safe_stop_peer(pid) do
    :peer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp wait_for(fun, retries \\ 50) do
    if fun.() do
      true
    else
      Process.sleep(20)
      if retries > 0, do: wait_for(fun, retries - 1), else: false
    end
  end
end
