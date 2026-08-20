defmodule OpenAgents.Forge.DeploymentClusterTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Forge.ArtifactFixtures
  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.Deployment
  alias OpenAgents.Forge.DeploymentNode

  @moduletag :cluster

  setup do
    ensure_distributed!()

    base =
      Path.join(System.tmp_dir!(), "deployment-cluster-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)

    previous = %{
      data: Application.get_env(:openagents, :forge_data_dir),
      expected: Application.get_env(:openagents, :forge_expected_fleet_size),
      allowlist: Application.get_env(:openagents, :forge_hot_load_allowlist)
    }

    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "local"))
    Application.put_env(:openagents, :forge_expected_fleet_size, 3)
    Application.put_env(:openagents, :forge_hot_load_allowlist, ["OpenAgents.Scratch."])
    reset_local_participant()

    on_exit(fn ->
      reset_local_participant()
      restore_env(:forge_data_dir, previous.data)
      restore_env(:forge_expected_fleet_size, previous.expected)
      restore_env(:forge_hot_load_allowlist, previous.allowlist)
      :persistent_term.erase({OpenAgents.Forge.BootConverge, :state})
      File.rm_rf(base)
    end)

    %{base: base}
  end

  test "three nodes prepare, canary, verify, commit, and finalize one exact candidate", %{
    base: base
  } do
    peers = start_peers(base, [%{}, %{}])
    fixture = versions("FleetSuccess", peers)

    try do
      assert {:ok, session} =
               Deployment.run(build(fixture), fixture.verified, fixture.built.bytes)

      assert length(session.expected_nodes) == 3
      assert session.canary == to_string(Node.self())

      for node <- nodes(peers) do
        assert revision(node, fixture.module) == "candidate"
        refute health(node)["ready"]
      end

      assert :ok = Deployment.finalize(session)

      for node <- nodes(peers) do
        assert health(node)["ready"]
        assert health(node)["revision"] == fixture.sha
      end
    after
      cleanup_fixture(fixture, peers)
      stop_peers(peers)
    end
  end

  test "one remote apply error restores exact prior code on every prepared node", %{base: base} do
    peers = start_peers(base, [%{}, %{apply: :error}])
    fixture = versions("FleetRollback", peers)

    try do
      assert {:error, outcome} =
               Deployment.run(build(fixture), fixture.verified, fixture.built.bytes)

      assert outcome.result == "reverted"
      assert outcome.rollback_verified
      assert length(outcome.expected_nodes) == 3

      for node <- nodes(peers) do
        assert revision(node, fixture.module) == "prior"
        assert health(node)["ready"]
      end
    after
      cleanup_fixture(fixture, peers)
      stop_peers(peers)
    end
  end

  test "an unverified rollback leaves the affected node out of readiness", %{base: base} do
    peers = start_peers(base, [%{rollback: :error}, %{apply: :error}])
    [{_rollback_peer, rollback_node}, _failing_peer] = peers
    fixture = versions("FleetDivergence", peers)

    try do
      assert {:error, outcome} =
               Deployment.run(build(fixture), fixture.verified, fixture.built.bytes)

      assert outcome.result == "failed"
      refute outcome.rollback_verified
      assert revision(rollback_node, fixture.module) == "candidate"
      refute health(rollback_node)["ready"]
    after
      cleanup_fixture(fixture, peers)
      stop_peers(peers)
    end
  end

  test "a timed-out participant blocks live and cannot be mistaken for rollback", %{base: base} do
    peers = start_peers(base, [%{}, %{apply: :timeout}], fault_timeout_ms: 1_000)
    fixture = versions("FleetTimeout", peers)

    try do
      assert {:error, outcome} =
               Deployment.run(build(fixture), fixture.verified, fixture.built.bytes,
                 timeout_ms: 100
               )

      assert outcome.result == "failed"
      refute outcome.rollback_verified
      assert outcome.error_code == "fleet_apply_failed"

      assert Enum.any?(outcome.node_results, fn {_node, result} ->
               String.contains?(result, "rollback_failed")
             end)
    after
      cleanup_fixture(fixture, peers)
      stop_peers(peers)
    end
  end

  test "membership loss after prepare aborts before fleet commit", %{base: base} do
    peers = start_peers(base, [%{}, %{}])
    [{peer_to_stop, _node_to_stop}, _survivor] = peers
    fixture = versions("MembershipLoss", peers)
    calls = :counters.new(1, [])

    membership = fn ->
      :counters.add(calls, 1, 1)
      call = :counters.get(calls, 1)
      if call == 3, do: safe_stop_peer(peer_to_stop)
      [Node.self() | Node.list()] |> Enum.uniq() |> Enum.sort()
    end

    try do
      assert {:error, outcome} =
               Deployment.run(build(fixture), fixture.verified, fixture.built.bytes,
                 members: membership,
                 timeout_ms: 500
               )

      assert outcome.result == "failed"
      refute outcome.rollback_verified
      assert outcome.error_code == "membership_changed"
      assert revision(Node.self(), fixture.module) == "prior"
    after
      cleanup_fixture(fixture, peers)
      stop_peers(peers)
    end
  end

  defp start_peers(base, faults, opts \\ []) do
    cookie = Node.get_cookie()
    paths = :code.get_path()

    faults
    |> Enum.with_index(1)
    |> Enum.map(fn {node_faults, index} ->
      suffix = System.unique_integer([:positive])
      name = String.to_atom("forge_deploy_peer#{index}_#{suffix}")

      {:ok, peer, node} =
        :peer.start_link(%{
          name: name,
          host: ~c"127.0.0.1",
          user: %{},
          shutdown: OpenAgents.Test.RemoteCover.shutdown(),
          args: [~c"-setcookie", to_charlist(Atom.to_string(cookie))]
        })

      :ok = :erpc.call(node, :code, :add_paths, [paths])
      :ok = :erpc.call(node, Application, :load, [:openagents])

      :ok =
        :erpc.call(node, Application, :put_env, [
          :openagents,
          :forge_data_dir,
          Path.join(base, "peer-#{index}")
        ])

      :ok =
        :erpc.call(node, Application, :put_env, [
          :openagents,
          :forge_hot_load_allowlist,
          ["OpenAgents.Scratch."]
        ])

      start_opts =
        [faults: node_faults]
        |> Keyword.put(:fault_timeout_ms, Keyword.get(opts, :fault_timeout_ms, 30_000))

      {:ok, _participant} = :erpc.call(node, DeploymentNode, :start, [start_opts])
      {peer, node}
    end)
  end

  defp versions(suffix, peers) do
    name = "OpenAgents.Scratch.#{suffix}#{System.unique_integer([:positive])}"
    module = Module.concat([name])
    prior_binary = compile(name, "prior")
    unload(module)
    candidate_binary = compile(name, "candidate")
    unload(module)

    prior_dir =
      Path.join(
        System.tmp_dir!(),
        "deployment-cluster-prior-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(prior_dir)
    File.write!(Path.join(prior_dir, Atom.to_string(module) <> ".beam"), prior_binary)

    for node <- nodes(peers) do
      assert true = call(node, :code, :add_patha, [to_charlist(prior_dir)])
      _purged = call(node, :code, :purge, [module])
      _deleted = call(node, :code, :delete, [module])
      assert {:module, ^module} = call(node, :code, :load_file, [module])
    end

    sha = random_sha()
    built = ArtifactFixtures.create!("openagents.com", sha, [{name, candidate_binary}])

    {:ok, verified} =
      BuildArtifact.verify(built.bytes,
        digest: built.digest,
        repo: "openagents.com",
        source_sha: sha,
        build_id: built.build_id
      )

    %{
      module: module,
      built: built,
      verified: verified,
      sha: sha,
      prior_dir: prior_dir
    }
  end

  defp build(fixture) do
    %{
      repo: "openagents.com",
      sha: fixture.sha,
      target_id: Ecto.UUID.generate(),
      build_id: fixture.built.build_id,
      modules: fixture.verified.modules,
      manifest: fixture.built.manifest
    }
  end

  defp compile(name, revision) do
    [{_module, binary}] =
      Code.compile_string("defmodule #{name} do\n  def revision, do: #{inspect(revision)}\nend")

    binary
  end

  defp revision(target_node, module) do
    if target_node == Node.self(),
      do: module.revision(),
      else: :erpc.call(target_node, module, :revision, [])
  end

  defp health(target_node) do
    if target_node == Node.self(),
      do: DeploymentNode.health(),
      else: :erpc.call(target_node, DeploymentNode, :health, [])
  end

  defp nodes(peers), do: [Node.self() | Enum.map(peers, &elem(&1, 1))]

  defp cleanup_fixture(fixture, peers) do
    Enum.each(nodes(peers), &safe_cleanup_node(&1, fixture))

    File.rm_rf(fixture.prior_dir)
  end

  defp safe_cleanup_node(target_node, fixture) do
    if target_node == Node.self() do
      unload(fixture.module)
      :code.del_path(to_charlist(fixture.prior_dir))
    else
      _result = :erpc.call(target_node, :code, :purge, [fixture.module])
      _result = :erpc.call(target_node, :code, :delete, [fixture.module])
      _result = :erpc.call(target_node, :code, :del_path, [to_charlist(fixture.prior_dir)])
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp stop_peers(peers) do
    Enum.each(peers, fn {peer, _node} -> safe_stop_peer(peer) end)
  end

  defp safe_stop_peer(peer) do
    :peer.stop(peer)
  catch
    :exit, _reason -> :ok
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  defp call(target_node, module, function, arguments) do
    if target_node == Node.self(),
      do: apply(module, function, arguments),
      else: :erpc.call(target_node, module, function, arguments)
  end

  defp reset_local_participant do
    :persistent_term.erase({DeploymentNode, :state})

    :sys.replace_state(DeploymentNode, fn state ->
      %{state | transactions: %{}, live: nil, divergence: nil, faults: %{}, notify: nil}
    end)
  end

  defp ensure_distributed! do
    if Node.self() == :nonode@nohost do
      suffix = System.unique_integer([:positive])
      name = String.to_atom("forge_deploy_test_#{suffix}@127.0.0.1")

      case :net_kernel.start([name, :longnames]) do
        :ok -> :ok
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      Node.set_cookie(:openagents_test_cookie)
    end

    :ok
  end

  defp random_sha, do: 20 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
