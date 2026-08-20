defmodule OpenAgents.MachinesTest do
  use OpenAgents.DataCase, async: true
  alias OpenAgents.Machines
  alias OpenAgents.Machines.Pairing

  defp user(key) do
    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: :erlang.phash2({__MODULE__, key}),
        github_login: "machines-#{key}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    user
  end

  defp start_pairing(attributes \\ %{}) do
    {:ok, started} =
      Machines.start_pairing(
        Map.merge(
          %{
            "name" => "test-box",
            "tier" => "probe",
            "platform" => "linux-x64",
            "agent_version" => "0.1.0",
            "roots" => ["/home/someone/code"]
          },
          attributes
        )
      )

    started
  end

  test "pairing stores only digests, never the code or poll secret" do
    %{pairing: pairing, code: code, poll_secret: poll_secret} = start_pairing()

    assert pairing.code_digest == :crypto.hash(:sha256, code)
    assert pairing.poll_secret_digest == :crypto.hash(:sha256, poll_secret)
    refute pairing.token_ciphertext
    assert pairing.status == "pending"
  end

  test "approve then claim hands the token over exactly once" do
    %{pairing: pairing, code: code, poll_secret: poll_secret} = start_pairing()
    owner = user("claim-once")

    assert {:error, :pairing_pending} = Machines.claim_pairing(pairing.id, poll_secret)

    assert {:ok, machine} = Machines.approve_pairing(owner, code)
    assert machine.user_id == owner.id
    assert machine.tier == "probe"

    assert {:ok, %{token: "smct_" <> _rest = token, machine_id: machine_id}} =
             Machines.claim_pairing(pairing.id, poll_secret)

    assert machine_id == machine.id
    assert Repo.get!(Pairing, pairing.id).token_ciphertext == nil
    assert {:error, :pairing_consumed} = Machines.claim_pairing(pairing.id, poll_secret)

    assert {:ok, authenticated} = Machines.authenticate_token(token)
    assert authenticated.id == machine.id
  end

  test "claim requires the correct poll secret" do
    %{pairing: pairing, code: code} = start_pairing()
    {:ok, _machine} = Machines.approve_pairing(user("wrong-secret"), code)

    assert {:error, :pairing_not_found} = Machines.claim_pairing(pairing.id, "wrong")
    assert {:error, :pairing_not_found} = Machines.claim_pairing("not-a-uuid", "wrong")
  end

  test "codes are normalized and single-use for approval" do
    %{code: code} = start_pairing()
    owner = user("normalize")

    dashed = String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)
    assert {:ok, _machine} = Machines.approve_pairing(owner, String.downcase(dashed))
    assert {:error, :pairing_consumed} = Machines.approve_pairing(owner, code)
    assert {:error, :pairing_not_found} = Machines.approve_pairing(owner, "NOPE1234")
  end

  test "expired pairings cannot be approved or claimed" do
    %{pairing: pairing, code: code, poll_secret: poll_secret} = start_pairing()

    pairing
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :pairing_expired} = Machines.approve_pairing(user("expired"), code)
    assert {:error, :pairing_expired} = Machines.claim_pairing(pairing.id, poll_secret)
  end

  test "machine tokens authenticate only while active" do
    %{pairing: pairing, code: code, poll_secret: poll_secret} = start_pairing()
    owner = user("revoked")
    {:ok, machine} = Machines.approve_pairing(owner, code)
    {:ok, %{token: token}} = Machines.claim_pairing(pairing.id, poll_secret)

    assert {:ok, _machine} = Machines.authenticate_token(token)
    assert {:ok, _revoked} = Machines.revoke_machine(owner, machine.id)
    assert {:error, :machine_revoked} = Machines.authenticate_token(token)
    assert {:error, :machine_not_found} = Machines.authenticate_token("smct_unknown")
    assert {:error, :machine_not_found} = Machines.authenticate_token("other_prefix")
  end

  test "machines are scoped to their owner" do
    %{code: code} = start_pairing()
    owner = user("owner-a")
    other = user("owner-b")
    {:ok, machine} = Machines.approve_pairing(owner, code)

    assert [%{id: listed_id}] = Machines.list_machines(owner.id)
    assert listed_id == machine.id
    assert Machines.list_machines(other.id) == []
    assert {:error, :machine_not_found} = Machines.get_machine(other.id, machine.id)
    assert {:error, :machine_not_found} = Machines.revoke_machine(other, machine.id)
  end

  test "probe reports are bounded" do
    %{code: code} = start_pairing()
    {:ok, machine} = Machines.approve_pairing(user("probe-bounds"), code)

    assert {:ok, updated} = Machines.store_probe(machine, %{"platform" => "linux"})
    assert updated.last_probe == %{"platform" => "linux"}

    oversized = %{"blob" => String.duplicate("a", 40_000)}
    assert {:error, :probe_report_too_large} = Machines.store_probe(machine, oversized)
    assert {:error, :invalid_probe_report} = Machines.store_probe(machine, "not a map")
  end
end
