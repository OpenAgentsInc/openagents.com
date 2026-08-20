defmodule OpenAgents.Cluster.DrainTest do
  @moduledoc """
  Proves the rolling-deploy drain: a node leaves the Raft cluster cleanly and
  the surviving members recompute a smaller quorum and keep committing — so a
  deploy that replaces one node at a time never drops the cluster.

  Tagged `:cluster`; run with `mix test --include cluster` (needs epmd).
  """
  use ExUnit.Case, async: false
  @moduletag :cluster

  alias OpenAgents.Cluster.{Drain, Ra}

  setup do
    case ensure_distributed() do
      :ok -> :ok
      :unavailable -> flunk("distribution unavailable — start epmd (`epmd -daemon`)")
    end
  end

  test "a drained node leaves Raft; survivors keep quorum and keep committing" do
    cookie = :erlang.get_cookie()
    {peer1, node1} = start_peer(:sarah_drain1, cookie)
    {peer2, node2} = start_peer(:sarah_drain2, cookie)
    on_exit(fn -> for p <- [peer1, peer2], do: safe_stop(p) end)

    Ra.start_in(data_dir(node()))
    :ok = :erpc.call(node1, Ra, :start_in, [data_dir(node1)])
    :ok = :erpc.call(node2, Ra, :start_in, [data_dir(node2)])

    assert {:ok, started} = Ra.start_cluster([node(), node1, node2])
    assert length(started) == 3

    id = "drain-#{System.unique_integer([:positive])}"
    assert {:ok, 1} = Ra.claim(id, :job)

    # Drain node2 — it leaves the Raft cluster cleanly.
    assert :ok = :erpc.call(node2, Drain, :leave_ra, [])

    assert eventually(fn -> length(Ra.members()) == 2 end),
           "drained node was not removed from the Raft cluster"

    refute node2 in Ra.members()

    # The two remaining members still form a quorum and keep committing.
    assert {:ok, 2} = Ra.claim(id, :job)
    assert {:ok, %{generation: 2}} = Ra.lookup(id)
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp data_dir(node) do
    base = Path.join(System.tmp_dir!(), "sarah_drain_test")
    short = node |> Atom.to_string() |> String.replace(~r/[^a-zA-Z0-9]/, "_")
    Path.join(base, "#{short}_#{System.unique_integer([:positive])}")
  end

  defp start_peer(name, cookie) do
    {:ok, peer, node} =
      :peer.start_link(%{
        name: unique_peer_name(name),
        host: ~c"127.0.0.1",
        shutdown: OpenAgents.Test.RemoteCover.shutdown(),
        args: [~c"-setcookie", Atom.to_charlist(cookie)]
      })

    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])
    {peer, node}
  end

  defp safe_stop(peer) do
    _ = :peer.stop(peer)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp ensure_distributed do
    cond do
      Node.self() != :nonode@nohost ->
        :ok

      # A fixed node name wedges this whole stage on any machine where an
      # earlier run left that name registered with epmd: net_kernel then
      # refuses to start and every distribution test flunks "unavailable".
      # Unique per run, and OpenAgents-named now that this is not Sarah's BEAM.
      match?({:ok, _}, :net_kernel.start([unique_test_node(), :longnames])) ->
        :erlang.set_cookie(Node.self(), :openagents_cluster_test_cookie)
        :ok

      true ->
        :unavailable
    end
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(100) && eventually(fun, attempts - 1)
    end
  end

  defp unique_test_node do
    :erlang.list_to_atom(~c"openagents_test_#{:erlang.unique_integer([:positive])}@127.0.0.1")
  end

  # Peer node names register with epmd too. A fixed name that a killed peer
  # left behind makes the next run's :peer.start_link fail, so the gate is
  # green once and wedged thereafter. Suffix every peer uniquely.
  defp unique_peer_name(base) do
    :erlang.list_to_atom(~c"#{base}_#{:erlang.unique_integer([:positive])}")
  end
end
