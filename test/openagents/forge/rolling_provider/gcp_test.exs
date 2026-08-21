defmodule OpenAgents.Forge.RollingProvider.GcpTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Cluster.Admission
  alias OpenAgents.Cluster.Drain
  alias OpenAgents.Forge.RollingNodeProbe
  alias OpenAgents.Forge.RollingProvider.Gcp
  alias OpenAgents.Test.RollingGcpDriver

  @sha String.duplicate("a", 40)
  @previous_sha String.duplicate("b", 40)
  @digest "sha256:" <> String.duplicate("c", 64)
  @previous_digest "sha256:" <> String.duplicate("d", 64)
  @nodes [:"openagents@fleet-1", :"openagents@fleet-2", :"openagents@fleet-3"]

  setup do
    previous = Application.get_env(:openagents, Gcp)
    on_exit(fn -> restore_config(previous) end)
    :ok
  end

  test "fences readiness, checks quorum, and replaces the exact mapped instance" do
    owner = self()

    rpc = fn node, module, function, arguments, _timeout ->
      send(owner, {:rpc, node, module, function, arguments})

      case {module, function} do
        {Admission, :remove} ->
          :ok

        {Admission, :restore} ->
          :ok

        {Drain, :drain} ->
          {:ok, 0}

        {RollingNodeProbe, :status} ->
          probe(node)

        {RollingGcpDriver, :replace} ->
          [instance, sha, digest, _config] = arguments
          send(owner, {:gcp_replace, instance, sha, digest})
          :ok
      end
    end

    put_config(rpc)
    context = context()

    assert :ok = Gcp.remove_readiness(hd(@nodes), context)
    assert {:ok, 0} = Gcp.drain(hd(@nodes), context)
    assert {:ok, %{ready: 2, quorum: true}} = Gcp.capacity(tl(@nodes), context)
    assert_receive {:rpc, _, RollingNodeProbe, :status, [3, @sha, @digest]}

    assert {:ok,
            %{
              member: true,
              ready: true,
              boot_converged: true,
              database_ready: true,
              sha: @sha,
              image_digest: @digest
            }} = Gcp.status(hd(@nodes), context)

    assert :ok = Gcp.replace(hd(@nodes), @digest, context)

    assert_receive {:rpc, :"openagents-deployer@openagents-deployer.staging.internal",
                    RollingGcpDriver, :replace,
                    ["openagents-fleet-1", @sha, @digest, compute_config]}

    assert compute_config[:project_id] == "openagents-staging-project"
    refute Keyword.has_key?(compute_config, :rpc)
    assert_receive {:gcp_replace, "openagents-fleet-1", @sha, @digest}

    assert :ok = Gcp.rollback(hd(@nodes), @previous_digest, context)
    assert_receive {:gcp_replace, "openagents-fleet-1", @previous_sha, @previous_digest}
  end

  test "refuses a staging project that matches production" do
    put_config(fn _node, _module, _function, _arguments, _timeout -> :ok end,
      project_id: "production-project",
      production_project_id: "production-project"
    )

    assert {:error, :staging_project_matches_production} =
             Gcp.remove_readiness(hd(@nodes), context())

    refute_receive {:gcp_replace, _instance, _sha, _digest}
  end

  test "refuses an unrecognized deployer node" do
    put_config(fn _node, _module, _function, _arguments, _timeout -> :ok end,
      deployer_node: :"openagents-deployer@untrusted.internal"
    )

    assert {:error, :invalid_deployer_node} = Gcp.remove_readiness(hd(@nodes), context())
  end

  test "fails capacity closed when Ra quorum is absent" do
    rpc = fn _node, RollingNodeProbe, :status, [_expected, @sha, @digest], _timeout ->
      Map.put(probe(hd(@nodes)), :ra_quorum, false)
    end

    put_config(rpc)
    assert {:ok, %{ready: 2, quorum: false}} = Gcp.capacity(tl(@nodes), context())
  end

  test "reports a rebooting node as unavailable when Erlang distribution disconnects" do
    rpc = fn _node, RollingNodeProbe, :status, [_expected, @sha, @digest], _timeout ->
      :erlang.error({:erpc, :noconnection})
    end

    put_config(rpc)

    assert {:ok,
            %{
              member: false,
              ready: false,
              boot_converged: false,
              database_ready: false,
              sha: nil,
              image_digest: nil
            }} = Gcp.status(hd(@nodes), context())
  end

  test "reports other reboot transport exits as unavailable" do
    rpc = fn _node, RollingNodeProbe, :status, [_expected, @sha, @digest], _timeout ->
      exit(:nodedown)
    end

    put_config(rpc)

    assert {:ok, %{ready: 0, quorum: false}} = Gcp.capacity([hd(@nodes)], context())
  end

  test "uses the bounded legacy probe while replacing an older fleet image" do
    owner = self()

    rpc = fn node, RollingNodeProbe, :status, arguments, _timeout ->
      send(owner, {:probe_arguments, arguments})

      case arguments do
        [3, @sha, @digest] -> {:error, :undef}
        [3] -> probe(node)
      end
    end

    put_config(rpc)

    assert {:ok, %{ready: 2, quorum: true}} = Gcp.capacity(tl(@nodes), context())
    assert_receive {:probe_arguments, [3, @sha, @digest]}
    assert_receive {:probe_arguments, [3]}
  end

  test "reports only connected nodes in the configured fleet inventory" do
    rpc = fn _node, _module, _function, _arguments, _timeout -> :ok end

    put_config(rpc,
      node_list: fn -> [hd(@nodes), :unknown@fleet, Enum.at(@nodes, 2)] end
    )

    assert Gcp.members() == [hd(@nodes), Enum.at(@nodes, 2)]
  end

  defp context do
    %{
      sha: @sha,
      previous_sha: @previous_sha,
      image_digest: @digest,
      previous_image_digest: @previous_digest,
      expected_nodes: @nodes
    }
  end

  defp probe(node) do
    %{
      member: true,
      ready: true,
      boot_converged: true,
      database_ready: true,
      sha: @sha,
      image_digest: @digest,
      ra_quorum: true,
      node: node
    }
  end

  defp put_config(rpc, overrides \\ []) do
    instances =
      @nodes
      |> Enum.with_index(1)
      |> Map.new(fn {node, index} -> {to_string(node), "openagents-fleet-#{index}"} end)

    config = [
      project_id: "openagents-staging-project",
      production_project_id: "production-project",
      zone: "us-central1-a",
      instances: instances,
      image_repository:
        "us-central1-docker.pkg.dev/openagents-staging-project/openagents/openagents",
      deployer_node: :"openagents-deployer@openagents-deployer.staging.internal",
      driver: RollingGcpDriver,
      rpc: rpc,
      rpc_timeout_ms: 100,
      compute_timeout_ms: 1_000
    ]

    Application.put_env(:openagents, Gcp, Keyword.merge(config, overrides))
  end

  defp restore_config(nil), do: Application.delete_env(:openagents, Gcp)
  defp restore_config(config), do: Application.put_env(:openagents, Gcp, config)
end
