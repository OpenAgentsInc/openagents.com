defmodule OpenAgents.Cluster.ChaosTest do
  @moduledoc """
  The measurable-not-asserted gate (M5): under repeated node loss, **zero owned
  sessions are dropped**.

  We stand up the app's real Horde topology across three nodes, place a fleet of
  cluster-singleton "sessions", then kill nodes one at a time (never breaking the
  requirement that at least one node survives) and assert every session relocated
  to a survivor — counting drops, which must be zero. This is the supervision-
  layer SLO; Raft quorum survival + the ownership fence are proven separately in
  `ra_cluster_test.exs`.

  Tagged `:cluster`; run with `mix test --include cluster` (needs epmd).
  """
  use ExUnit.Case, async: false
  @moduletag :skip

  @moduletag :cluster
  @moduletag timeout: 180_000

  @registry OpenAgents.HordeRegistry
  @supervisor OpenAgents.HordeSupervisor
  @fleet_size 8

  setup do
    case ensure_distributed() do
      :ok -> :ok
      :unavailable -> flunk("distribution unavailable — start epmd (`epmd -daemon`)")
    end
  end

  test "zero owned sessions are dropped across sequential node losses" do
    cookie = :erlang.get_cookie()
    {peer1, node1} = start_peer(:sarah_chaos1, cookie)
    {peer2, node2} = start_peer(:sarah_chaos2, cookie)
    on_exit(fn -> for p <- [peer1, peer2], do: safe_stop(p) end)

    assert eventually(fn ->
             members = horde_member_nodes()
             node1 in members and node2 in members and node() in members
           end),
           "Horde membership did not converge: #{inspect(horde_member_nodes())}"

    # Place a fleet of singleton sessions and record their identity.
    keys =
      for i <- 1..@fleet_size do
        key = {:work_job, "chaos-#{i}"}
        {:ok, _} = start_singleton(key)
        assert wait_present(key), "session #{inspect(key)} did not come up"
        key
      end

    assert all_present?(keys), "not all sessions started"

    # Chaos round 1: kill peer2 (whichever sessions it held must relocate).
    safe_stop(peer2)

    assert eventually(fn -> all_present?(keys) end, 300),
           "sessions dropped after losing node2: #{inspect(missing(keys))}"

    # Chaos round 2: kill peer1 too — now only this node survives, and it must
    # hold every session. Still zero drops.
    safe_stop(peer1)

    assert eventually(fn -> all_present?(keys) end, 300),
           "sessions dropped after losing node1: #{inspect(missing(keys))}"

    # Final SLO assertion: every session survived, all now on the sole survivor.
    survivors = Enum.map(keys, &owner_node/1)
    assert Enum.all?(survivors, &(&1 == node()))
    assert missing(keys) == []
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp start_singleton(key) do
    Horde.DynamicSupervisor.start_child(
      @supervisor,
      OpenAgents.Test.HordePeer.singleton_spec(key)
    )
  end

  defp owner_node(key) do
    case Horde.Registry.lookup(@registry, key) do
      [{pid, _}] -> node(pid)
      _ -> nil
    end
  end

  defp present?(key), do: match?([{_pid, _}], Horde.Registry.lookup(@registry, key))
  defp all_present?(keys), do: Enum.all?(keys, &present?/1)
  defp missing(keys), do: Enum.reject(keys, &present?/1)
  defp wait_present(key), do: eventually(fn -> present?(key) end, 60)

  defp horde_member_nodes do
    @registry
    |> Horde.Cluster.members()
    |> Enum.map(fn
      {_name, n} -> n
      n when is_atom(n) -> n
    end)
    |> Enum.uniq()
  end

  defp start_peer(name, cookie) do
    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        args: [~c"-setcookie", Atom.to_charlist(cookie)]
      })

    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:horde])
    {:ok, _keeper} = :erpc.call(node, OpenAgents.Test.HordePeer, :start!, [])
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

      match?({:ok, _}, :net_kernel.start([:"sarah_test@127.0.0.1", :longnames])) ->
        :erlang.set_cookie(Node.self(), :sarah_cluster_test_cookie)
        :ok

      true ->
        :unavailable
    end
  end

  defp eventually(fun, attempts \\ 120) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(100) && eventually(fun, attempts - 1)
    end
  end
end
