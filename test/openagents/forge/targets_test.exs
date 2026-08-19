defmodule OpenAgents.Forge.TargetsTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.Target
  alias OpenAgents.Forge.Targets

  test "promote a target" do
    assert {:ok, %Target{} = target} =
             Targets.promote("OpenAgents/openagents.com", "abc123", "operator-1")

    assert target.repo == "OpenAgents/openagents.com"
    assert target.sha == "abc123"
    assert target.promoted_by == "operator-1"
    assert target.status == "promoted"
  end

  test "refuse promotion of an unknown SHA" do
    bad_store = fn _repo, _sha -> :error end

    assert {:error, :unknown_sha} =
             Targets.promote(
               "OpenAgents/openagents.com",
               "badsha",
               "operator-1",
               commit_store: bad_store
             )
  end

  test "complete lifecycle from promoted to live" do
    {:ok, target} = Targets.promote("OpenAgents/openagents.com", "abc123", "operator-1")

    for status <- ["building", "built", "deploying", "live"] do
      assert {:ok, %Target{} = updated} = Targets.transition(target.id, status)
      assert updated.status == status
    end
  end

  test "refuse invalid transitions" do
    {:ok, target} = Targets.promote("OpenAgents/openagents.com", "abc123", "operator-1")

    assert {:error, {:invalid_transition, "promoted", "live"}} =
             Targets.transition(target.id, "live")
  end

  test "refuse transitions out of a terminal state" do
    {:ok, target} = Targets.promote("OpenAgents/openagents.com", "abc123", "operator-1")

    assert {:ok, %Target{} = built} = Targets.transition(target.id, "building")
    assert {:ok, %Target{} = built} = Targets.transition(built.id, "built")
    assert {:ok, %Target{} = deploying} = Targets.transition(built.id, "deploying")
    assert {:ok, %Target{} = live} = Targets.transition(deploying.id, "live")

    assert {:error, {:terminal, "live"}} = Targets.transition(live.id, "reverted")
  end

  test "pinning back to an older SHA creates a new latest target" do
    repo = "OpenAgents/openagents.com"

    {:ok, first} = Targets.promote(repo, "sha-1", "operator-1")
    {:ok, second} = Targets.promote(repo, "sha-2", "operator-1")
    assert Targets.latest(repo).id == second.id

    {:ok, third} = Targets.promote(repo, "sha-1", "operator-1")
    assert Targets.latest(repo).id == third.id
    assert third.sha == "sha-1"
    refute third.id == first.id
  end

  test "bound details to 100 keys and 32KB" do
    too_many = Map.new(0..100, fn i -> {"key#{i}", "value"} end)

    assert {:error, {:invalid, %Ecto.Changeset{} = changeset}} =
             Targets.promote("OpenAgents/openagents.com", "abc123", "operator-1",
               details: too_many
             )

    assert "exceeds the 100-key bound" in errors_on(changeset).details

    huge_string = String.duplicate("x", 40_000)

    assert {:error, {:invalid, %Ecto.Changeset{} = changeset}} =
             Targets.promote("OpenAgents/openagents.com", "def456", "operator-1",
               details: %{data: huge_string}
             )

    assert "exceeds the 32KB bound" in errors_on(changeset).details
  end
end
