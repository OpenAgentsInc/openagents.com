defmodule OpenAgents.Deployments.LifecycleTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Deployments.Lifecycle

  test "every terminal state is final" do
    for state <- ~w(succeeded failed cancelled superseded) do
      assert Lifecycle.successors(state) == []
    end
  end

  test "only a deploying run can succeed" do
    for {state, successors} <- Lifecycle.transitions(), state != "deploying" do
      refute "succeeded" in successors
    end

    assert Lifecycle.allowed?("deploying", "succeeded")
  end

  test "a run cannot skip the provider" do
    refute Lifecycle.allowed?("queued", "succeeded")
    refute Lifecycle.allowed?("requested", "deploying")
  end

  test "a deploying run cannot be superseded out from under the provider" do
    refute Lifecycle.allowed?("deploying", "superseded")
    assert Lifecycle.allowed?("deploying", "cancelled")
  end

  test "an illegal transition is reported as itself" do
    assert Lifecycle.check("succeeded", "deploying") ==
             {:error, {:illegal_transition, "succeeded", "deploying"}}

    assert Lifecycle.check("queued", "deploying") == :ok
  end

  test "an unknown state has no successors" do
    assert Lifecycle.successors("nonsense") == []
    refute Lifecycle.allowed?("nonsense", "queued")
  end
end
