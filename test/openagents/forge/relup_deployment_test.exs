defmodule OpenAgents.Forge.RelupDeploymentTest do
  # Not async: the reverse-direction case drives the real RelupNode against the
  # singleton test release handler.
  use ExUnit.Case, async: false

  alias OpenAgents.Forge.RelupDeployment
  alias OpenAgents.ReleaseState
  alias OpenAgents.ReleaseState.State
  alias OpenAgents.Test.ReleaseHandler

  @sha String.duplicate("a", 40)
  @from_sha String.duplicate("c", 40)
  @digest String.duplicate("b", 64)
  @manifest_digest String.duplicate("d", 64)
  @nodes [:first@local, :second@local, :third@local]

  test "upgrades and makes each node permanent before touching the next" do
    parent = self()

    rpc = fn node, _module, function, _arguments, _timeout ->
      send(parent, {:phase, node, function})
      {:ok, %{"phase" => to_string(function)}}
    end

    assert {:ok, %{status: "live"}} =
             RelupDeployment.run(request(),
               members: fn -> @nodes end,
               gate_verifier: fn @sha -> {:ok, %{}} end,
               rpc: rpc
             )

    expected =
      for node <- @nodes,
          phase <- [
            :stage,
            :verify_stage,
            :unpack,
            :check_install,
            :install,
            :verify,
            :make_permanent,
            :verify
          ],
          do: {:phase, node, phase}

    assert drain_messages([]) == expected
  end

  test "reverses an unhealthy node and aborts before the next node" do
    parent = self()

    rpc = fn node, _module, function, arguments, _timeout ->
      send(parent, {:phase, node, function})

      case {node, function, arguments} do
        {:second@local, :verify, [_request, :current]} -> {:error, :unhealthy}
        {:second@local, :reverse, _arguments} -> {:ok, %{"restored" => true}}
        _other -> {:ok, %{}}
      end
    end

    assert {:error, %{status: "failed", error_code: error_code}} =
             RelupDeployment.run(request(),
               members: fn -> @nodes end,
               gate_verifier: fn @sha -> {:ok, %{}} end,
               rpc: rpc
             )

    assert is_binary(error_code)
    events = drain_messages([])
    assert {:phase, :second@local, :reverse} in events
    assert {:phase, :first@local, :reverse} in events
    refute Enum.any?(events, fn {_, node, _phase} -> node == :third@local end)
  end

  test "reverses the newly permanent node when membership changes before continuation" do
    parent = self()
    calls = start_supervised!({Agent, fn -> 0 end})

    members = fn ->
      Agent.get_and_update(calls, fn count ->
        next = count + 1
        members = if next >= 3, do: Enum.drop(@nodes, -1), else: @nodes
        {members, next}
      end)
    end

    rpc = fn node, _module, function, _arguments, _timeout ->
      send(parent, {:phase, node, function})
      {:ok, %{}}
    end

    assert {:error, %{status: "failed"}} =
             RelupDeployment.run(request(),
               members: members,
               gate_verifier: fn @sha -> {:ok, %{}} end,
               rpc: rpc
             )

    assert {:phase, :first@local, :reverse} in drain_messages([])
  end

  defp request do
    %{
      sha: @sha,
      from_revision: @from_sha,
      release_name: "openagents",
      from_version: "0.1.0",
      to_version: "0.2.0",
      from_state_version: 1,
      to_state_version: 2,
      artifact_bytes: "artifact",
      artifact_digest: @digest,
      package_manifest_digest: @manifest_digest,
      expected_nodes: @nodes,
      expected_fleet_size: 3
    }
  end

  describe "version admission" do
    test "admits an arbitrary forward semver transition, not only the proof pair" do
      parent = self()

      rpc = fn node, _module, function, _arguments, _timeout ->
        send(parent, {:phase, node, function})
        {:ok, %{}}
      end

      request =
        request()
        |> Map.merge(%{from_version: "0.2.0", to_version: "0.3.0", from_state_version: 2})

      assert {:ok, %{status: "live", from_version: "0.2.0", to_version: "0.3.0"}} =
               RelupDeployment.run(request,
                 members: fn -> @nodes end,
                 gate_verifier: fn @sha -> {:ok, %{}} end,
                 rpc: rpc
               )

      assert length(drain_messages([])) == 24
    end

    test "refuses a degenerate transition" do
      request = request() |> Map.put(:to_version, request().from_version)

      assert {:error, :degenerate_version_transition} =
               RelupDeployment.run(request,
                 members: fn -> @nodes end,
                 gate_verifier: fn @sha -> {:ok, %{}} end,
                 rpc: fn _, _, _, _, _ -> {:ok, %{}} end
               )
    end

    test "refuses malformed versions" do
      assert {:error, :invalid_from_version} =
               RelupDeployment.run(request() |> Map.put(:from_version, "zero-point-twelve"),
                 members: fn -> @nodes end,
                 gate_verifier: fn @sha -> {:ok, %{}} end,
                 rpc: fn _, _, _, _, _ -> {:ok, %{}} end
               )

      assert {:error, :invalid_to_version} =
               RelupDeployment.run(request() |> Map.put(:to_version, "0.2"),
                 members: fn -> @nodes end,
                 gate_verifier: fn @sha -> {:ok, %{}} end,
                 rpc: fn _, _, _, _, _ -> {:ok, %{}} end
               )
    end

    test "refuses a malformed source revision or package manifest digest" do
      assert {:error, :invalid_from_git_sha} =
               RelupDeployment.run(request() |> Map.put(:from_revision, "not-a-sha"))

      assert {:error, :invalid_package_manifest_digest} =
               RelupDeployment.run(request() |> Map.put(:package_manifest_digest, "short"))
    end

    test "refuses state version regression and unsupported state versions" do
      regression =
        request()
        |> Map.merge(%{from_version: "0.2.0", to_version: "0.3.0", from_state_version: 2})
        |> Map.put(:to_state_version, 1)

      assert {:error, :state_version_regression} =
               RelupDeployment.run(regression,
                 members: fn -> @nodes end,
                 gate_verifier: fn @sha -> {:ok, %{}} end,
                 rpc: fn _, _, _, _, _ -> {:ok, %{}} end
               )

      unsupported = request() |> Map.put(:to_state_version, 3)

      assert {:error, :unsupported_to_state_version} =
               RelupDeployment.run(unsupported,
                 members: fn -> @nodes end,
                 gate_verifier: fn @sha -> {:ok, %{}} end,
                 rpc: fn _, _, _, _, _ -> {:ok, %{}} end
               )
    end
  end

  describe "the reverse direction on a same-schema pair" do
    test "restores the from release, its permanence, and the process state" do
      state = start_supervised!({ReleaseState, name: nil})
      :ok = ReleaseState.observe("retained", state)

      installer = fn
        "0.3.0" -> migrate(state, ~c"0.2.0", schema_version: 2)
        "0.2.0" -> migrate(state, {:down, ~c"0.3.0"}, schema_version: 2)
      end

      start_supervised!(
        {ReleaseHandler,
         %{
           releases: [{~c"openagents", ~c"0.2.0", [], :permanent}],
           pair: {"0.2.0", "0.3.0"},
           on_install: installer
         }}
      )

      artifact = "immutable 0.3.0 artifact"

      root =
        Path.join(
          System.tmp_dir!(),
          "openagents-relup-fleet-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(root, "releases"))
      on_exit(fn -> File.rm_rf!(root) end)

      node_opts = [
        release_root: root,
        release_handler: ReleaseHandler,
        generate_config: fn _version -> :ok end,
        revision: fn -> request().sha end,
        health: &unready_once/0,
        state: fn -> ReleaseState.snapshot(state) end
      ]

      request =
        request()
        |> Map.merge(%{
          from_version: "0.2.0",
          to_version: "0.3.0",
          from_state_version: 2,
          to_state_version: 2,
          artifact_bytes: artifact,
          artifact_digest: sha256(artifact),
          expected_nodes: [Node.self()],
          expected_fleet_size: 1
        })

      assert {:error, %{status: "failed"}} =
               RelupDeployment.run(request,
                 members: fn -> [Node.self()] end,
                 gate_verifier: fn @sha -> {:ok, %{}} end,
                 rpc: fn _node, module, function, arguments, _timeout ->
                   apply(module, function, arguments ++ [node_opts])
                 end
               )

      assert %State{schema_version: 2, observations: ["retained"], integrity: integrity} =
               ReleaseState.snapshot(state)

      assert is_binary(integrity)

      assert Enum.any?(ReleaseHandler.which_releases(), fn {_name, version, _apps, status} ->
               to_string(version) == "0.2.0" and status == :permanent
             end)
    end
  end

  # The post-install health check fails once, which is what sends the node down
  # the reverse path; every later check reports ready.
  defp unready_once do
    case Process.get(:relup_health_calls, 0) do
      0 ->
        Process.put(:relup_health_calls, 1)
        %{"ready" => false}

      _later ->
        %{"ready" => true}
    end
  end

  defp migrate(pid, version, extra) do
    :ok = :sys.suspend(pid)
    :ok = :sys.change_code(pid, ReleaseState, version, extra)
    :ok = :sys.resume(pid)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp drain_messages(acc) do
    receive do
      event -> drain_messages([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
