defmodule OpenAgents.Cluster.RaClusterTest do
  @moduledoc """
  Real multi-node proof of the Ra (Raft) session registry: commands commit
  through consensus across nodes, reads are linearizable from any node, the
  generation fence holds cluster-wide, and the cluster keeps serving after a
  node (including the current leader/owner) dies — as long as a quorum remains.

  Tagged `:cluster`, excluded by default; run with `mix test --include cluster`
  (needs epmd).
  """
  use ExUnit.Case, async: false
  @moduletag :cluster

  alias OpenAgents.Cluster.Ra

  setup do
    case ensure_distributed() do
      :ok -> :ok
      :unavailable -> flunk("distribution unavailable — start epmd (`epmd -daemon`)")
    end
  end

  test "3-node Raft: cross-node commit, linearizable reads, fence, and quorum survival" do
    cookie = :erlang.get_cookie()
    {peer1, node1} = start_peer(:openagents_ra_peer1, cookie)
    {peer2, node2} = start_peer(:openagents_ra_peer2, cookie)
    on_exit(fn -> for p <- [peer1, peer2], do: safe_stop(p) end)

    nodes = [node(), node1, node2]

    # Start Ra on all three nodes (unique data dir per node), then form the
    # Raft cluster across them.
    Ra.start_in(data_dir(node()))
    :ok = :erpc.call(node1, Ra, :start_in, [data_dir(node1)])
    :ok = :erpc.call(node2, Ra, :start_in, [data_dir(node2)])

    assert {:ok, started} = Ra.start_cluster(nodes)
    assert length(started) == 3

    id = "sess-#{System.unique_integer([:positive])}"

    # Claim from the test node -> generation 1, committed via consensus.
    assert {:ok, 1} = Ra.claim(id, :delegation)
    assert :ok = Ra.checkpoint(id, 1, %{step: "a"})

    # Linearizable read from a *different* node sees the committed checkpoint.
    assert {:ok, %{generation: 1, checkpoint: %{step: "a"}, owner: owner1}} =
             :erpc.call(node1, Ra, :lookup, [id])

    assert owner1 == node()

    # Re-claim from peer2 (a handoff) -> generation 2, owner peer2.
    assert {:ok, 2} = :erpc.call(node2, Ra, :claim, [id, :delegation])

    # The old owner (generation 1) is now fenced cluster-wide.
    assert {:fenced, 2} = Ra.checkpoint(id, 1, %{step: "stale"})
    assert {:ok, %{generation: 2, owner: ^node2}} = Ra.lookup(id)

    # Kill peer2 — the current owner AND a Raft member. A quorum (2/3) remains.
    safe_stop(peer2)

    # The cluster keeps serving: a survivor re-claims the orphaned session,
    # bumping to generation 3. (Raft re-elects if peer2 was leader; the command
    # commits once a new leader is up, within the call timeout / a short retry.)
    assert eventually(fn ->
             match?({:ok, gen} when gen >= 3, :erpc.call(node1, Ra, :claim, [id, :delegation]))
           end),
           "the 2-node quorum did not keep committing after the owner node died"

    assert {:ok, %{generation: gen, owner: ^node1}} = Ra.lookup(id)
    assert gen >= 3
  end

  test "a node joins an existing cluster via Ra.join and becomes a voting member" do
    cookie = :erlang.get_cookie()
    {peer1, node1} = start_peer(:openagents_ra_join1, cookie)
    {peer2, node2} = start_peer(:openagents_ra_join2, cookie)
    on_exit(fn -> for p <- [peer1, peer2], do: safe_stop(p) end)

    Ra.start_in(data_dir(node()))
    :ok = :erpc.call(node1, Ra, :start_in, [data_dir(node1)])
    :ok = :erpc.call(node2, Ra, :start_in, [data_dir(node2)])

    # Form the cluster with just two nodes (the test node + peer1).
    assert {:ok, started} = Ra.start_cluster([node(), node1])
    assert length(started) == 2

    id = "join-#{System.unique_integer([:positive])}"
    assert {:ok, 1} = Ra.claim(id, :job)

    # peer2 joins the existing cluster through the test node (add_member on a
    # member + start its own server), and becomes a voting member of three.
    join_result = :erpc.call(node2, Ra, :join, [node()])

    assert eventually(fn -> length(:erpc.call(node2, Ra, :members, [node2])) == 3 end),
           "peer2 did not become a member of the 3-node cluster (join=#{inspect(join_result)})"

    # The joined node has caught up and reads the committed state.
    assert eventually(fn ->
             match?({:ok, %{generation: 1}}, :erpc.call(node2, Ra, :lookup, [id]))
           end)
  end

  test "a phantom member (local server down, still in config) restarts and rejoins" do
    cookie = :erlang.get_cookie()
    {peer1, node1} = start_peer(:openagents_ra_phantom1, cookie)
    {peer2, node2} = start_peer(:openagents_ra_phantom2, cookie)
    on_exit(fn -> for p <- [peer1, peer2], do: safe_stop(p) end)

    Ra.start_in(data_dir(node()))
    :ok = :erpc.call(node1, Ra, :start_in, [data_dir(node1)])
    :ok = :erpc.call(node2, Ra, :start_in, [data_dir(node2)])

    assert {:ok, _} = Ra.start_cluster([node(), node1, node2])

    # Stop peer2's local Raft server, leaving it in the cluster config but not
    # running here — the phantom-member state an ungraceful restart produces.
    # Ask the module for the server ID so this test cannot drift from the
    # configured cluster name.
    :ok = :erpc.call(node2, :ra, :stop_server, [:default, Ra.server_id(node2)])

    assert eventually(fn -> :erpc.call(node2, Ra, :members, [node2]) == [] end),
           "peer2 local server did not stop"

    # The surviving members still see the full config and hold quorum.
    assert length(Ra.members()) == 3

    # Bring the phantom back: ensure_local_server restarts it and it rejoins.
    assert :ok = :erpc.call(node2, Ra, :ensure_local_server, [[node(), node1, node2]])

    assert eventually(fn -> length(:erpc.call(node2, Ra, :members, [node2])) == 3 end),
           "phantom member did not rejoin after ensure_local_server"
  end

  test "a partitioned minority cannot double-run: only the majority commits" do
    cookie = :erlang.get_cookie()
    # standard_io control channels: the peers must survive losing their dist
    # connection to us — that loss IS the partition under test.
    {peer1, node1} = start_peer(:openagents_ra_part1, cookie, connection: :standard_io)
    {peer2, node2} = start_peer(:openagents_ra_part2, cookie, connection: :standard_io)
    on_exit(fn -> for p <- [peer1, peer2], do: safe_stop(p) end)

    Ra.start_in(data_dir(node()))
    :ok = :erpc.call(node1, Ra, :start_in, [data_dir(node1)])
    :ok = :erpc.call(node2, Ra, :start_in, [data_dir(node2)])
    assert {:ok, _} = Ra.start_cluster([node(), node1, node2])

    id = "part-#{System.unique_integer([:positive])}"
    assert {:ok, 1} = Ra.claim(id, :delegation)

    # Ask peer2 to (a) cut itself off from both majority nodes shortly — a
    # closure cannot ship to the peer (the test module isn't on its code
    # path), and a remote disconnect would sever the erpc reply channel — and
    # (b) attempt a claim mid-partition, recording the outcome for us to read
    # after the heal.
    minority_script = """
    majority = [:"#{node()}", :"#{node1}"]

    spawn(fn ->
      Process.sleep(300)
      Enum.each(majority, &Node.disconnect/1)
      Process.sleep(1_000)
      result = OpenAgents.Cluster.Ra.claim("#{id}", :delegation)
      :persistent_term.put(:partition_claim_result, result)
    end)
    """

    {_pid, _binding} = :erpc.call(node2, Code, :eval_string, [minority_script])

    # Enforce the cut from the majority side as well.
    true = :erpc.call(node1, Node, :disconnect, [node2])
    _ = Node.disconnect(node2)

    assert eventually(fn -> node2 not in Node.list() end), "partition did not take"

    # The majority (this node + peer1) keeps committing: a handoff re-claim.
    assert eventually(fn -> match?({:ok, 2}, Ra.claim(id, :delegation)) end),
           "the majority partition stopped committing"

    # Heal the partition and read what the minority's claim attempt returned.
    assert eventually(fn -> Node.connect(node2) == true end), "heal failed"

    minority =
      eventually_value(fn ->
        :erpc.call(node2, :persistent_term, :get, [:partition_claim_result, :pending])
      end)

    # The minority must NOT have gotten a claim acknowledged while cut off —
    # Raft cannot commit without quorum, so it saw a timeout/error (or, if its
    # queued command survived to commit after the heal, it serialized *after*
    # the majority's claim — never concurrently). Either way: no double-run.
    case minority do
      {:ok, generation} -> assert generation > 2, "minority committed inside the partition"
      other -> assert match?({:error, _}, other), "unexpected minority outcome: #{inspect(other)}"
    end

    # One current owner, fence intact: the majority's generation-2 ownership
    # stands unless a post-heal serialized claim (gen 3) superseded it, and the
    # pre-partition generation-1 owner is fenced out cluster-wide.
    assert {:fenced, _current} = Ra.checkpoint(id, 1, %{step: "stale"})
    assert {:ok, %{generation: final_gen}} = Ra.lookup(id)
    assert final_gen >= 2
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Polls until `fun` returns a non-pending value; flunks after ~10s.
  defp eventually_value(fun, attempts \\ 100) do
    case fun.() do
      :pending ->
        if attempts <= 0 do
          flunk("condition never produced a value")
        else
          Process.sleep(100)
          eventually_value(fun, attempts - 1)
        end

      value ->
        value
    end
  end

  defp data_dir(node) do
    base = Path.join(System.tmp_dir!(), "openagents_ra_test")

    short =
      node |> Atom.to_string() |> String.replace(~r/[^a-zA-Z0-9]/, "_")

    Path.join(base, "#{short}_#{System.unique_integer([:positive])}")
  end

  defp start_peer(name, cookie, opts \\ []) do
    base = %{
      name: unique_peer_name(name),
      host: ~c"127.0.0.1",
      shutdown: OpenAgents.Test.RemoteCover.shutdown(),
      args: [~c"-setcookie", Atom.to_charlist(cookie)]
    }

    # connection: :standard_io keeps the control channel off distribution so a
    # deliberate partition doesn't kill the peer (the partition test).
    options =
      case Keyword.get(opts, :connection) do
        nil -> base
        connection -> Map.put(base, :connection, connection)
      end

    {:ok, peer, node} = :peer.start_link(options)

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
