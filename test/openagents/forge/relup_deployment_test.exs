defmodule OpenAgents.Forge.RelupDeploymentTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Forge.RelupDeployment

  @sha String.duplicate("a", 40)
  @digest String.duplicate("b", 64)
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
      release_name: "openagents",
      from_version: "0.1.0",
      to_version: "0.2.0",
      from_state_version: 1,
      to_state_version: 2,
      artifact_bytes: "artifact",
      artifact_digest: @digest,
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

  defp drain_messages(acc) do
    receive do
      event -> drain_messages([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
