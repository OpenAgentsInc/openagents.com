defmodule OpenAgents.Forge.RelupTopologyTest do
  @moduledoc """
  Executable proof for RELEASE-008.

  The refusal is driven against the real running `libring` application, not a
  fixture: `HashRing.App.start/2` returns a `DynamicSupervisor` pid, so
  `:supervisor.get_callback_module/1` raises `badrecord` for
  `HashRing.Supervisor` on this exact OTP release. Every assertion below runs the
  real OTP walk that `release_handler_1:get_master_procs/3` runs.
  """

  use ExUnit.Case, async: true

  alias OpenAgents.Forge.RelupDeployment
  alias OpenAgents.Forge.RelupNode
  alias OpenAgents.Forge.RelupTopology

  @sha String.duplicate("a", 40)
  @from_sha String.duplicate("c", 40)
  @digest String.duplicate("b", 64)
  @manifest_digest String.duplicate("d", 64)
  @nodes [:first@local, :second@local, :third@local]

  setup do
    {:ok, _started} = Application.ensure_all_started(:libring)
    :ok
  end

  describe "the real libring topology" do
    test "OTP cannot identify the DynamicSupervisor libring starts" do
      assert Process.whereis(HashRing.Supervisor)
      assert {:error, :unreadable_top_supervisor} = RelupTopology.top_supervisor(:libring)
    end

    test "the refusal names the application and its supervisor" do
      assert {:error, {:incompatible_topology, ["libring:HashRing.Supervisor"]}} =
               RelupTopology.refuse(applications: fn -> [:libring] end)
    end

    test "the running system is refused and libring is one of the reasons" do
      assert {:error, {:incompatible_topology, entries}} = RelupTopology.refuse()
      assert "libring:HashRing.Supervisor" in entries
    end

    test "an application whose top process is an OTP supervisor is admitted" do
      assert {:ok, module} = RelupTopology.top_supervisor(:openagents)
      assert is_atom(module)
      assert RelupTopology.refuse(applications: fn -> [:openagents] end) == :ok
    end

    test "a library application has no supervision tree to inspect" do
      assert RelupTopology.top_supervisor(:crypto) == :no_supervision_tree
      assert RelupTopology.refuse(applications: fn -> [:crypto] end) == :ok
    end

    test "the report stays bounded and content-free" do
      report = RelupTopology.report()

      assert report["schema"] == "openagents.relup-topology.v1"
      assert report["applications"] > 0
      assert length(report["incompatible"]) <= 16
      assert Enum.all?(report["incompatible"], &(is_binary(&1) and byte_size(&1) <= 96))
    end
  end

  describe "the node refuses before OTP changes anything" do
    test "check_topology refuses the running topology" do
      assert {:error, {:incompatible_topology, entries}} = RelupNode.check_topology(request())
      assert "libring:HashRing.Supervisor" in entries
    end

    test "check_topology admits a topology OTP can inspect" do
      assert {:ok, %{"phase" => "topology_checked"}} =
               RelupNode.check_topology(request(), applications: fn -> [:openagents] end)
    end
  end

  describe "the coordinator aborts before the point of no return" do
    test "no node is staged, installed, or reversed" do
      parent = self()

      rpc = fn node, module, function, arguments, _timeout ->
        send(parent, {:phase, node, function})
        apply(module, function, arguments ++ [[]])
      end

      assert {:error, result} =
               RelupDeployment.run(request(),
                 members: fn -> @nodes end,
                 gate_verifier: fn @sha -> {:ok, %{}} end,
                 rpc: rpc
               )

      assert result.status == "failed"
      assert result.sha == @sha
      assert result.from_revision == @from_sha
      assert result.artifact_digest == @digest
      assert result.package_manifest_digest == @manifest_digest

      assert result.error_code ==
               "check_topology:incompatible_topology:libring:HashRing.Supervisor"

      assert result.node_results == %{
               "first@local" => "check_topology:incompatible_topology:libring:HashRing.Supervisor"
             }

      # The first node refused on the first step. Nothing was staged, nothing
      # was unpacked, `install_release` was never called, and because the
      # current release never changed there is no reverse installation.
      assert drain_phases([]) == [{:phase, :first@local, :check_topology}]
    end
  end

  defp drain_phases(collected) do
    receive do
      {:phase, _node, _function} = message -> drain_phases([message | collected])
    after
      0 -> Enum.reverse(collected)
    end
  end

  defp request do
    %{
      sha: @sha,
      from_revision: @from_sha,
      artifact_digest: @digest,
      package_manifest_digest: @manifest_digest,
      release_name: "openagents",
      from_version: "0.1.0",
      to_version: "0.2.0",
      from_state_version: 1,
      to_state_version: 2,
      artifact_bytes: "release bytes",
      expected_nodes: @nodes,
      expected_fleet_size: length(@nodes)
    }
  end
end
