defmodule OpenAgents.Forge.TargetsTest do
  @moduledoc """
  The two surfaces of `OpenAgents.Forge.Targets` that the end-to-end
  lifecycle test (`OpenAgents.Forge.TargetLifecycleTest`, which drives a real
  bare repo) does not reach: the injectable `commit_store`, and the bounded
  `details` map.

  Promotability and the transition table are deliberately NOT re-asserted
  here — they have one contract and one home. This file used to promote
  never-pushed SHAs like `"abc123"` through a test-environment bypass, which
  contradicted that contract ("only pushed commits are ever promotable") and
  meant the precondition was never actually exercised anywhere.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.Target
  alias OpenAgents.Forge.Targets

  test "a hosted user repository is not deployable" do
    assert {:error, :repository_not_deployable} =
             Targets.promote(
               Ecto.UUID.generate(),
               String.duplicate("a", 40),
               "operator:test",
               commit_store: fn _repo, _sha -> :ok end
             )
  end

  @repo "OpenAgentsInc/openagents.com"

  # A SHA that is well-formed but not in any repo, so only the injected
  # store decides whether it is promotable.
  defp sha, do: 20 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp promote(attrs \\ []) do
    Targets.promote(
      Keyword.get(attrs, :repo, @repo),
      Keyword.get(attrs, :sha, sha()),
      Keyword.get(attrs, :operator, "operator-1"),
      Keyword.take(attrs, [:commit_store, :details])
      |> Keyword.put_new(:commit_store, fn _repo, _sha -> :ok end)
    )
  end

  test "an accepting commit store promotes the commit" do
    sha = sha()

    assert {:ok, %Target{} = target} = promote(sha: sha)
    assert target.repo == @repo
    assert target.sha == sha
    assert target.promoted_by == "operator-1"
    assert target.status == "promoted"
  end

  test "a refusing commit store refuses the promotion" do
    assert {:error, :unknown_sha} = promote(commit_store: fn _repo, _sha -> :error end)
  end

  test "a commit store may name its own reason" do
    store = fn _repo, _sha -> {:error, :mirror_behind} end
    assert {:error, :mirror_behind} = promote(commit_store: store)
  end

  test "a malformed SHA is refused before the store is consulted" do
    store = fn _repo, _sha -> flunk("commit store must not be consulted") end

    assert {:error, :invalid_sha} =
             Targets.promote(@repo, "not-a-sha!", "operator-1", commit_store: store)
  end

  test "details are bounded to 100 keys and 32KB per value" do
    too_many = Map.new(0..100, fn i -> {"key#{i}", "value"} end)

    assert {:error, {:invalid, %Ecto.Changeset{} = changeset}} = promote(details: too_many)
    assert "exceeds the 100-key bound" in errors_on(changeset).details

    huge = String.duplicate("x", 40_000)

    assert {:error, {:invalid, %Ecto.Changeset{} = changeset}} =
             promote(details: %{data: huge})

    assert "exceeds the 32KB bound" in errors_on(changeset).details
  end

  test "latest/1 and transition/2 are the current/advance aliases" do
    {:ok, first} = promote()
    {:ok, second} = promote()

    assert Targets.latest(@repo).id == second.id
    assert {:ok, %Target{status: "building"}} = Targets.transition(first.id, "building")

    assert {:error, {:invalid_transition, "promoted", "live"}} =
             Targets.transition(second.id, "live")
  end
end
