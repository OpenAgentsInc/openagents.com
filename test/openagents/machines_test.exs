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

  # The window a sealed pairing token can live in. `TokenVault` keeps exactly
  # one AAD because of this bound: a version-1 blob would have to survive a
  # release change, and no row holds ciphertext longer than this. CANON-002.
  test "a pairing window is bounded, so sealed ciphertext cannot outlive a release" do
    %{pairing: pairing} = start_pairing()

    assert DateTime.diff(pairing.expires_at, pairing.inserted_at, :second) <= 600
    assert DateTime.compare(pairing.expires_at, pairing.inserted_at) == :gt
  end

  test "approve then claim hands the token over exactly once" do
    %{pairing: pairing, code: code, poll_secret: poll_secret} = start_pairing()
    owner = user("claim-once")

    assert {:error, :pairing_pending} = Machines.claim_pairing(pairing.id, poll_secret)

    assert {:ok, machine} = Machines.approve_pairing(owner, code)
    assert machine.user_id == owner.id
    assert machine.tier == "probe"
    assert DateTime.compare(machine.token_expires_at, DateTime.utc_now()) == :gt

    assert {:ok, %{token: "smct_" <> _rest = token, machine_id: machine_id}} =
             Machines.claim_pairing(pairing.id, poll_secret)

    assert machine_id == machine.id
    assert Repo.get!(Pairing, pairing.id).token_ciphertext == nil
    assert {:error, :pairing_consumed} = Machines.claim_pairing(pairing.id, poll_secret)

    assert {:ok, authenticated} = Machines.authenticate_token(token)
    assert authenticated.id == machine.id
  end

  test "concurrent claims have exactly one winner" do
    %{pairing: pairing, code: code, poll_secret: poll_secret} = start_pairing()
    assert {:ok, _machine} = Machines.approve_pairing(user("concurrent-claim"), code)
    parent = self()

    tasks =
      for _attempt <- 1..2 do
        Task.async(fn ->
          send(parent, {:claim_ready, self()})

          receive do
            :claim -> Machines.claim_pairing(pairing.id, poll_secret)
          end
        end)
      end

    Enum.each(tasks, fn %{pid: pid} ->
      assert_receive {:claim_ready, ^pid}
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end)

    Enum.each(tasks, &send(&1.pid, :claim))
    results = Enum.map(tasks, &Task.await/1)

    assert Enum.count(results, &match?({:ok, %{token: "smct_" <> _rest}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :pairing_consumed})) == 1
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

  test "expired machine tokens fail closed" do
    %{pairing: pairing, code: code, poll_secret: poll_secret} = start_pairing()
    owner = user("expired-token")
    {:ok, machine} = Machines.approve_pairing(owner, code)
    {:ok, %{token: token}} = Machines.claim_pairing(pairing.id, poll_secret)

    backdated = DateTime.add(DateTime.utc_now(), -31, :day)

    Repo.update_all(from(m in OpenAgents.Machines.Machine, where: m.id == ^machine.id),
      set: [inserted_at: backdated]
    )

    Repo.get!(OpenAgents.Machines.Machine, machine.id)
    |> Ecto.Changeset.change(token_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :machine_expired} = Machines.authenticate_token(token)
    refute Machines.active_machine?(owner.id)
    assert Machines.approval_receipts(owner.id, "conversation:test") == []
  end

  test "an approved pairing cannot be claimed after its one-time window" do
    %{pairing: pairing, code: code, poll_secret: poll_secret} = start_pairing()
    owner = user("expired-approved-pairing")
    assert {:ok, machine} = Machines.approve_pairing(owner, code)

    pairing
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :pairing_expired} = Machines.claim_pairing(pairing.id, poll_secret)
    assert %{status: "expired", token_ciphertext: nil} = Repo.get!(Pairing, pairing.id)
    assert %{status: "revoked"} = Repo.get!(OpenAgents.Machines.Machine, machine.id)
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
