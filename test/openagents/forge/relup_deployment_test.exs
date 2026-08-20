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

  defp drain_messages(acc) do
    receive do
      event -> drain_messages([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
