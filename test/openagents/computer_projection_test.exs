defmodule OpenAgents.ComputerProjectionTest do
  @moduledoc """
  `machines.revoked_at` was written by both revocation paths and read by
  nothing: `ComputerProjection.project/1` omitted it, so the account export and
  the computers API reported that a computer was revoked without saying when.
  """

  use OpenAgents.DataCase, async: true

  alias OpenAgents.ComputerProjection
  alias OpenAgents.Machines
  alias OpenAgents.Machines.Machine
  alias OpenAgents.Repo

  defp user(key) do
    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: :erlang.phash2({__MODULE__, key}),
        github_login: "projection-#{key}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    user
  end

  defp computer(owner, key) do
    {:ok, %{code: code}} = Machines.start_pairing(%{"name" => "box-#{key}", "tier" => "probe"})
    {:ok, machine} = Machines.approve_pairing(owner, code)
    machine
  end

  test "an active computer reports no revocation" do
    projection = ComputerProjection.project(computer(user("active"), "active"))

    assert projection["status"] == "active"
    assert Map.fetch!(projection, "revoked_at") == nil
  end

  test "a revoked computer reports when it was revoked" do
    owner = user("revoked")
    machine = computer(owner, "revoked")

    {:ok, revoked} = Machines.revoke_machine(owner, machine.id)
    projection = ComputerProjection.project(revoked)

    assert projection["status"] == "revoked"
    assert projection["revoked_at"] == DateTime.to_iso8601(revoked.revoked_at)
  end

  test "the stamp the account export carries is the stamp the row holds" do
    owner = user("export")
    machine = computer(owner, "export")
    {:ok, _revoked} = Machines.revoke_machine(owner, machine.id)

    # Projected from a fresh read, the way every caller reaches it.
    [projected] = Enum.map(Machines.list_machines(owner.id), &ComputerProjection.project/1)
    stored = Repo.get!(Machine, machine.id)

    assert projected["revoked_at"] == DateTime.to_iso8601(stored.revoked_at)
  end

  test "a computer revoked by an elapsed pairing reports its stamp too" do
    owner = user("swept")
    machine = computer(owner, "swept")

    OpenAgents.Machines.Pairing
    |> Repo.get_by!(machine_id: machine.id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -3_600, :second))
    |> Repo.update!()

    assert Machines.expire_elapsed_pairings() == 1

    projection = ComputerProjection.project(Repo.get!(Machine, machine.id))
    assert projection["status"] == "revoked"
    assert is_binary(projection["revoked_at"])
  end

  test "the projection still withholds the token, its digest, and the raw probe" do
    machine = computer(user("secrets"), "secrets")
    {:ok, machine} = Machines.store_probe(machine, %{"acp_agents" => [], "secret" => "x"})

    projection = ComputerProjection.project(machine)

    refute Map.has_key?(projection, "token_digest")
    refute Map.has_key?(projection, "token_expires_at")
    refute Map.has_key?(projection, "last_probe")
  end
end
