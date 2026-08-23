defmodule OpenAgents.Forge.RollingReplacementTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Forge.RollingReplacement
  alias OpenAgents.Test.RollingAuthority
  alias OpenAgents.Test.RollingProvider

  @sha String.duplicate("a", 40)
  @previous_sha String.duplicate("d", 40)
  @target "sha256:" <> String.duplicate("b", 64)
  @previous "sha256:" <> String.duplicate("c", 64)
  @nodes [:first@local, :second@local, :third@local]
  @target_id "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

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

  test "uses the provider's exact infrastructure inventory by default" do
    start_provider(nil)

    assert {:ok, %{status: "live"}} =
             RollingReplacement.run(request(),
               provider: RollingProvider,
               authority: RollingAuthority,
               gate_verifier: fn @sha -> {:ok, %{}} end,
               wait_attempts: 1,
               wait_interval_ms: 0
             )
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
               authority: RollingAuthority,
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

  test "publishes the authorized rolling identity before the first node is replaced" do
    start_provider(nil)

    assert {:ok, %{status: "live", target_id: @target_id}} = run()

    assert {@target_id,
            %{
              sha: @sha,
              image_digest: @target,
              previous_sha: @previous_sha,
              previous_image_digest: @previous,
              expected_nodes: ["first@local", "second@local", "third@local"]
            }} = RollingAuthority.authorized()

    # The authorization is durable before the fleet is touched at all, so the
    # first replacement node boots into an already-authorized identity.
    assert RollingAuthority.fleet_events_at_authorization() == []
    assert hd(RollingAuthority.calls()) == {:authorize, @target_id}

    assert RollingAuthority.observed() == %{
             "first@local" => %{sha: @sha, image_digest: @target},
             "second@local" => %{sha: @sha, image_digest: @target},
             "third@local" => %{sha: @sha, image_digest: @target}
           }
  end

  test "replaces nothing when the target refuses the rolling authorization" do
    start_supervised!({RollingAuthority, %{refuse: :rolling_authority_conflict}})

    start_supervised!(
      {RollingProvider,
       %{
         capacity: nil,
         events: [],
         fail_node: nil,
         members: @nodes,
         previous_sha: @previous_sha,
         rolled_back: MapSet.new(),
         digests: Map.new(@nodes, &{&1, @previous})
       }}
    )

    assert {:error, {:rolling_authority_refused, :rolling_authority_conflict}} = run()
    assert RollingProvider.events() == []
  end

  test "records the previous identity for a node it rolled back" do
    start_provider(:second@local)

    assert {:error, %{status: "failed", recovery: "last_known_good_restored"}} = run()

    assert RollingAuthority.observed() == %{
             "first@local" => %{sha: @sha, image_digest: @target},
             "second@local" => %{sha: @previous_sha, image_digest: @previous}
           }
  end

  test "refuses a request that names no Forge target" do
    start_provider(nil)

    assert {:error, :invalid_target_id} =
             RollingReplacement.run(Map.delete(request(), :target_id),
               provider: RollingProvider,
               authority: RollingAuthority,
               members: fn -> @nodes end,
               gate_verifier: fn @sha -> {:ok, %{}} end
             )

    assert RollingProvider.events() == []
  end

  defp run do
    RollingReplacement.run(request(),
      provider: RollingProvider,
      authority: RollingAuthority,
      members: fn -> @nodes end,
      gate_verifier: fn @sha -> {:ok, %{}} end,
      wait_attempts: 1,
      wait_interval_ms: 0
    )
  end

  defp request do
    %{
      target_id: @target_id,
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
    start_supervised!({RollingAuthority, %{}})

    start_supervised!(
      {RollingProvider,
       %{
         capacity: capacity,
         events: [],
         fail_node: fail_node,
         members: @nodes,
         previous_sha: @previous_sha,
         rolled_back: MapSet.new(),
         digests: Map.new(@nodes, &{&1, @previous})
       }}
    )
  end
end
