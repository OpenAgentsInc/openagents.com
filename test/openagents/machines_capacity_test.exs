defmodule OpenAgents.MachinesCapacityTest do
  use OpenAgents.SarahDataCase, async: false
  @moduletag :skip
  alias OpenAgents.Machines
  alias OpenAgents.Machines.Machine

  test "revoking one of eight active machines frees exactly one capacity slot" do
    owner = user("replace")

    machines =
      for index <- 1..8 do
        pair!(owner, "computer-#{index}")
      end

    ninth = start_pairing!("computer-9")
    assert {:error, :too_many_machines} = Machines.approve_pairing(owner, ninth.code)

    assert {:ok, revoked} = Machines.revoke_machine(owner, List.first(machines).id)
    assert revoked.status == "revoked"
    assert {:ok, replacement} = Machines.approve_pairing(owner, ninth.code)
    assert replacement.status == "active"

    assert Repo.aggregate(active_machines(owner.id), :count) == 8

    assert Repo.aggregate(from(machine in Machine, where: machine.user_id == ^owner.id), :count) ==
             9
  end

  test "concurrent approvals at the boundary admit only one computer" do
    owner = user("concurrent")

    for index <- 1..7 do
      pair!(owner, "existing-#{index}")
    end

    codes =
      for index <- 1..2 do
        start_pairing!("candidate-#{index}").code
      end

    results =
      codes
      |> Task.async_stream(
        fn code -> Machines.approve_pairing(owner, code) end,
        max_concurrency: 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %Machine{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :too_many_machines}, &1)) == 1
    assert Repo.aggregate(active_machines(owner.id), :count) == 8
  end

  test "one owner's capacity cannot block or be changed by another owner" do
    full_owner = user("full-owner")
    other_owner = user("other-owner")

    full_owner_machines =
      for index <- 1..8 do
        pair!(full_owner, "full-#{index}")
      end

    assert {:error, :machine_not_found} =
             Machines.revoke_machine(other_owner, List.first(full_owner_machines).id)

    assert {:ok, %Machine{user_id: other_owner_id}} = pair(other_owner, "other-computer")
    assert other_owner_id == other_owner.id
    assert Repo.aggregate(active_machines(full_owner.id), :count) == 8
  end

  defp user(key) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: unique,
        github_login: "capacity-#{key}-#{unique}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    user
  end

  defp pair!(owner, name) do
    assert {:ok, machine} = pair(owner, name)
    machine
  end

  defp pair(owner, name) do
    pairing = start_pairing!(name)
    Machines.approve_pairing(owner, pairing.code)
  end

  defp start_pairing!(name) do
    assert {:ok, pairing} =
             Machines.start_pairing(%{
               "name" => name,
               "tier" => "probe",
               "platform" => "linux-x64",
               "agent_version" => "0.1.0",
               "roots" => ["/home/someone/code"]
             })

    pairing
  end

  defp active_machines(user_id) do
    from(machine in Machine,
      where: machine.user_id == ^user_id and machine.status == "active"
    )
  end
end
