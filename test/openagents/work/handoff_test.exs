defmodule OpenAgents.Work.HandoffTest do
  @moduledoc """
  M1 chaos proof at the supervision layer: a cluster-wide singleton under the
  app's own Horde topology (`OpenAgents.HordeRegistry` + `OpenAgents.HordeSupervisor`,
  `members: :auto`, `keys: :unique`) **relocates to a survivor when its node
  dies**, and stays a singleton (exactly one registration) across the handoff.

  This is the mechanism `OpenAgents.Work.JobServer`/`DelegationServer` ride on: the
  app-specific rehydrate-and-finish glue (`claim_for_run` adopt +
  `finish_job` terminal idempotency) is proven against the real DB in
  `work_job_test.exs`; here we prove the distributed relocation itself, across
  real BEAM nodes. Tagged `:cluster`, excluded by default; run with
  `mix test --include cluster` (needs epmd).
  """
  use ExUnit.Case, async: false

  @moduletag :cluster

  @registry OpenAgents.HordeRegistry
  @supervisor OpenAgents.HordeSupervisor

  setup do
    case ensure_distributed() do
      :ok -> :ok
      :unavailable -> flunk("distribution unavailable — start epmd (`epmd -daemon`)")
    end
  end

  test "a Horde singleton relocates to a survivor when its node dies, staying unique" do
    cookie = :erlang.get_cookie()
    {peer1, node1} = start_peer(:sarah_handoff_peer1, cookie)
    {peer2, node2} = start_peer(:sarah_handoff_peer2, cookie)

    on_exit(fn ->
      for p <- [peer1, peer2], do: safe_stop(p)
    end)

    # All three nodes run the app's Horde components and converge on membership.
    assert eventually(fn ->
             members = horde_member_nodes()
             node1 in members and node2 in members and node() in members
           end),
           "Horde membership did not converge across the 3 nodes: #{inspect(horde_member_nodes())}"

    # Find a singleton key whose owner node is peer1, so killing peer1 forces a
    # real cross-node relocation. Horde places by hashing the child id over the
    # member ring, so we probe keys until one lands on peer1.
    {key, pid0} = singleton_on(node1)
    assert node(pid0) == node1

    # Kill peer1 (hard node loss).
    safe_stop(peer1)

    # The singleton reappears on a surviving node, with a NEW pid, and there is
    # exactly one registration for the key (no split/duplicate).
    assert eventually(
             fn ->
               case Horde.Registry.lookup(@registry, key) do
                 [{pid, _}] -> node(pid) in [node(), node2] and pid != pid0
                 _ -> false
               end
             end,
             300
           ),
           "singleton did not relocate to a survivor after node loss"

    assert [{pid1, _}] = Horde.Registry.lookup(@registry, key)
    assert node(pid1) in [node(), node2]
    assert node(pid1) != node1
    # The relocated Agent still answers — it was restarted, not orphaned.
    # (:sys.get_state ships no closure to the remote node, unlike Agent.get.)
    assert :sys.get_state(pid1) == :handoff_singleton
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Start a singleton Agent (a stdlib process, so no custom module needs to be
  # loaded on peers) under Horde, probing keys until it lands on `target_node`.
  defp singleton_on(target_node) do
    Enum.find_value(0..60, fn i ->
      key = {:work_job, "handoff-#{i}"}
      spec = OpenAgents.Test.HordePeer.singleton_spec(key)

      case Horde.DynamicSupervisor.start_child(@supervisor, spec) do
        {:ok, _pid} ->
          # give Horde a beat to route/register, then see where it landed
          if pid = wait_lookup(key) do
            if node(pid) == target_node, do: {key, pid}, else: nil
          end

        {:error, {:already_started, _}} ->
          nil

        _ ->
          nil
      end
    end) || flunk("could not place a singleton on #{inspect(target_node)}")
  end

  defp wait_lookup(key) do
    Enum.find_value(1..40, fn _ ->
      case Horde.Registry.lookup(@registry, key) do
        [{pid, _}] -> pid
        _ -> Process.sleep(50) && nil
      end
    end)
  end

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
        name: unique_peer_name(name),
        host: ~c"127.0.0.1",
        shutdown: OpenAgents.Test.RemoteCover.shutdown(),
        args: [~c"-setcookie", Atom.to_charlist(cookie)]
      })

    # Share this node's code paths so horde + deps + support modules load.
    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:horde])

    # Start the app's Horde topology on the peer, owned by a persistent keeper
    # (see OpenAgents.Test.HordePeer) so it lives with the node and dies with it.
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

  defp eventually(fun, attempts \\ 120) do
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
