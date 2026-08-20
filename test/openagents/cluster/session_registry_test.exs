defmodule OpenAgents.Cluster.SessionRegistryTest do
  @moduledoc """
  Unit-level proof of the Raft machine's fence, driven by calling `apply/3`
  directly — no cluster needed, because the machine is a pure function of
  command + prior state.
  """
  use ExUnit.Case, async: true

  alias OpenAgents.Cluster.SessionRegistry, as: Reg

  defp run(cmd, state), do: Kernel.apply(Reg, :apply, [%{}, cmd, state])

  test "claim bumps the generation monotonically and records the owner" do
    s0 = Reg.init(%{})
    assert {s1, {:ok, 1}} = run({:claim, "j1", :delegation, :a@h}, s0)

    assert Reg.lookup("j1").(s1) == %{
             kind: :delegation,
             generation: 1,
             owner: :a@h,
             status: :claimed,
             checkpoint: nil
           }

    # A re-claim (handoff to another node) bumps the generation and re-owns.
    assert {s2, {:ok, 2}} = run({:claim, "j1", :delegation, :b@h}, s1)
    assert Reg.lookup("j1").(s2).owner == :b@h
    assert Reg.lookup("j1").(s2).generation == 2
  end

  test "checkpoint is accepted for the current generation and fenced for a stale one" do
    s0 = Reg.init(%{})
    {s1, {:ok, 1}} = run({:claim, "j1", :job, :a@h}, s0)
    {s2, {:ok, 2}} = run({:claim, "j1", :job, :b@h}, s1)

    # The new owner (gen 2) checkpoints successfully.
    assert {s3, :ok} = run({:checkpoint, "j1", 2, %{step: 5}}, s2)
    assert Reg.lookup("j1").(s3).checkpoint == %{step: 5}

    # The superseded zombie (gen 1) is fenced — its checkpoint is rejected and
    # the committed state is untouched.
    assert {^s3, {:fenced, 2}} = run({:checkpoint, "j1", 1, %{step: 99}}, s3)
    assert Reg.lookup("j1").(s3).checkpoint == %{step: 5}
  end

  test "finish is fenced for a stale generation; a zombie cannot terminal-commit" do
    s0 = Reg.init(%{})
    {s1, {:ok, 1}} = run({:claim, "j1", :job, :a@h}, s0)
    {s2, {:ok, 2}} = run({:claim, "j1", :job, :b@h}, s1)

    # Zombie (gen 1) tries to finish — fenced, state unchanged.
    assert {^s2, {:fenced, 2}} = run({:finish, "j1", 1}, s2)
    assert Reg.lookup("j1").(s2).status == :claimed

    # Live owner (gen 2) finishes.
    assert {s3, :ok} = run({:finish, "j1", 2}, s2)
    assert Reg.lookup("j1").(s3).status == :terminal
  end

  test "a terminal session is never re-claimed" do
    s0 = Reg.init(%{})
    {s1, {:ok, 1}} = run({:claim, "j1", :job, :a@h}, s0)
    {s2, :ok} = run({:finish, "j1", 1}, s1)

    assert {^s2, {:error, {:terminal, 1}}} = run({:claim, "j1", :job, :b@h}, s2)
  end

  test "owned_by lists live sessions for a node, excluding terminal ones" do
    s0 = Reg.init(%{})
    {s1, _} = run({:claim, "j1", :job, :a@h}, s0)
    {s2, _} = run({:claim, "j2", :job, :a@h}, s1)
    {s3, _} = run({:claim, "j3", :job, :b@h}, s2)
    {s4, :ok} = run({:finish, "j1", 1}, s3)

    assert Enum.sort(Reg.owned_by(:a@h).(s4)) == ["j2"]
    assert Reg.owned_by(:b@h).(s4) == ["j3"]
  end
end
