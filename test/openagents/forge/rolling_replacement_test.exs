defmodule OpenAgents.Forge.RollingReplacementTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Forge.RollingReplacement
  alias OpenAgents.Test.RollingProvider

  @sha String.duplicate("a", 40)
  @previous_sha String.duplicate("d", 40)
  @target "sha256:" <> String.duplicate("b", 64)
  @previous "sha256:" <> String.duplicate("c", 64)
  @nodes [:first@local, :second@local, :third@local]

  test "replaces one node at a time only after readiness returns" do
    start_provider(nil)

    assert {:ok, %{status: "live"}} = run()

    replace_events =
      RollingProvider.events()
      |> Enum.filter(&match?({:replace, _node, _digest}, &1))

    assert replace_events == [
             {:replace, :first@local, @target},
             {:replace, :second@local, @target},
             {:replace, :third@local, @target}
           ]
  end

  test "restores the prior image and aborts before another replacement when rejoin fails" do
    start_provider(:second@local)

    assert {:error, %{status: "failed", recovery: "last_known_good_restored"}} = run()

    events = RollingProvider.events()
    assert {:rollback, :second@local, @previous} in events
    refute {:replace, :third@local, @target} in events
  end

  test "refuses deployment without an exact gate receipt" do
    start_provider(nil)

    assert {:error, :missing_gate_receipt} =
             RollingReplacement.run(request(),
               provider: RollingProvider,
               members: fn -> @nodes end,
               gate_verifier: fn @sha -> {:error, :missing_gate_receipt} end
             )

    assert RollingProvider.events() == []
  end

  test "restores readiness without replacing an image when drained capacity is unsafe" do
    start_provider(nil, {:ok, %{ready: 1, quorum: true}})

    assert {:error, %{status: "failed", recovery: "readiness_restored"}} = run()

    events = RollingProvider.events()
    assert {:restore_readiness, :first@local} in events
    refute Enum.any?(events, &match?({:replace, _node, _digest}, &1))
  end

  defp run do
    RollingReplacement.run(request(),
      provider: RollingProvider,
      members: fn -> @nodes end,
      gate_verifier: fn @sha -> {:ok, %{}} end,
      wait_attempts: 1,
      wait_interval_ms: 0
    )
  end

  defp request do
    %{
      sha: @sha,
      previous_sha: @previous_sha,
      image_digest: @target,
      previous_image_digest: @previous,
      expected_nodes: @nodes,
      expected_fleet_size: 3,
      minimum_ready: 2
    }
  end

  defp start_provider(fail_node, capacity \\ nil) do
    start_supervised!(
      {RollingProvider,
       %{
         capacity: capacity,
         events: [],
         fail_node: fail_node,
         previous_sha: @previous_sha,
         rolled_back: MapSet.new(),
         digests: Map.new(@nodes, &{&1, @previous})
       }}
    )
  end
end
