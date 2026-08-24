defmodule OpenAgents.Machines.PairingExpiryTest do
  @moduledoc """
  IDENTITY-011: a pairing window closes on its own clock.

  Before the sweep, `claim_pairing/2` was the only thing that expired a
  pairing, so every property here failed for the same reason: nobody polled.
  """

  use OpenAgents.DataCase, async: true

  alias OpenAgents.Inference
  alias OpenAgents.Machines
  alias OpenAgents.Machines.{Machine, Pairing, TokenVault}
  alias OpenAgents.Repo

  defp user(key) do
    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: :erlang.phash2({__MODULE__, key}),
        github_login: "pairing-expiry-#{key}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    user
  end

  defp start_pairing do
    {:ok, started} = Machines.start_pairing(%{"name" => "box", "tier" => "probe"})
    started
  end

  defp close_window(pairing_id) do
    Pairing
    |> Repo.get!(pairing_id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -3_600, :second))
    |> Repo.update!()
  end

  test "an approved pairing nobody claims loses its sealed token" do
    %{pairing: pairing, code: code} = start_pairing()
    {:ok, _machine} = Machines.approve_pairing(user("sealed"), code)

    assert is_binary(Repo.get!(Pairing, pairing.id).token_ciphertext),
           "the fixture must actually hold a sealed token"

    close_window(pairing.id)

    assert Machines.expire_elapsed_pairings() == 1

    swept = Repo.get!(Pairing, pairing.id)
    assert swept.status == "expired"
    assert is_nil(swept.token_ciphertext)
  end

  test "the computer an unclaimed pairing created is revoked" do
    %{pairing: pairing, code: code} = start_pairing()
    {:ok, machine} = Machines.approve_pairing(user("computer"), code)
    close_window(pairing.id)

    assert Machines.expire_elapsed_pairings() == 1

    revoked = Repo.get!(Machine, machine.id)
    assert revoked.status == "revoked"
    assert revoked.revoked_at
  end

  test "the revoked computer's inference grants close with it" do
    %{pairing: pairing, code: code} = start_pairing()
    owner = user("grants")
    {:ok, machine} = Machines.approve_pairing(owner, code)
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(owner)

    {:ok, grant, _token} =
      Inference.mint(%{
        owner_visitor_id: conversation.visitor_id,
        conversation_id: conversation.id,
        machine_id: machine.id
      })

    assert grant.status == "active"

    close_window(pairing.id)
    assert Machines.expire_elapsed_pairings() == 1

    assert Repo.reload!(grant).status == "revoked"
  end

  test "the sweep announces the revocation so an open channel closes" do
    %{pairing: pairing, code: code} = start_pairing()
    {:ok, machine} = Machines.approve_pairing(user("broadcast"), code)
    :ok = Phoenix.PubSub.subscribe(OpenAgents.PubSub, "machine:#{machine.id}")

    close_window(pairing.id)
    assert Machines.expire_elapsed_pairings() == 1

    machine_id = machine.id
    assert_receive {:machine_revoked, ^machine_id}
  end

  test "a pending pairing nobody approves expires too" do
    %{pairing: pairing} = start_pairing()
    close_window(pairing.id)

    assert Machines.expire_elapsed_pairings() == 1
    assert Repo.get!(Pairing, pairing.id).status == "expired"
  end

  test "a pairing still inside its window is left alone" do
    %{pairing: pairing, code: code} = start_pairing()
    {:ok, machine} = Machines.approve_pairing(user("fresh"), code)

    assert Machines.expire_elapsed_pairings() == 0

    assert Repo.get!(Pairing, pairing.id).status == "approved"
    assert Repo.get!(Machine, machine.id).status == "active"
  end

  test "a claimed pairing is never swept, and its computer keeps working" do
    %{pairing: pairing, code: code, poll_secret: poll_secret} = start_pairing()
    {:ok, machine} = Machines.approve_pairing(user("claimed"), code)
    {:ok, %{token: token}} = Machines.claim_pairing(pairing.id, poll_secret)

    close_window(pairing.id)
    assert Machines.expire_elapsed_pairings() == 0

    assert Repo.get!(Pairing, pairing.id).status == "claimed"
    assert {:ok, %Machine{id: id}} = Machines.authenticate_token(token)
    assert id == machine.id
  end

  test "the sweep is idempotent" do
    %{pairing: pairing, code: code} = start_pairing()
    {:ok, _machine} = Machines.approve_pairing(user("idempotent"), code)
    close_window(pairing.id)

    assert Machines.expire_elapsed_pairings() == 1
    assert Machines.expire_elapsed_pairings() == 0
  end

  # The claim path and the sweep must reach the same state, or the sweep would
  # be a second, weaker expiry rather than the same one on a clock.
  test "the sweep leaves the row where a late claim would have left it" do
    %{pairing: swept, code: swept_code} = start_pairing()
    {:ok, _} = Machines.approve_pairing(user("parity-a"), swept_code)
    close_window(swept.id)
    assert Machines.expire_elapsed_pairings() == 1

    %{pairing: claimed, code: claimed_code, poll_secret: secret} = start_pairing()
    {:ok, _} = Machines.approve_pairing(user("parity-b"), claimed_code)
    close_window(claimed.id)
    assert {:error, :pairing_expired} = Machines.claim_pairing(claimed.id, secret)

    fields = fn id ->
      row = Repo.get!(Pairing, id)
      {row.status, row.token_ciphertext, Repo.get!(Machine, row.machine_id).status}
    end

    assert fields.(swept.id) == fields.(claimed.id)
  end

  # The sweep's selection is the only reader `machine_pairings_expires_at_index`
  # has, and it is invisible to every outcome above: `expire_elapsed_pairing/1`
  # re-reads each row under `FOR UPDATE` and refuses anything terminal or still
  # fresh, so widening the predicate leaves all of those tests green while the
  # index quietly stops being used. It is proved directly for that reason.
  describe "the sweep's selection" do
    test "names elapsed pending and approved pairings and nothing else" do
      %{pairing: elapsed_pending} = start_pairing()
      close_window(elapsed_pending.id)

      %{pairing: elapsed_approved, code: approved_code} = start_pairing()
      {:ok, _} = Machines.approve_pairing(user("select-approved"), approved_code)
      close_window(elapsed_approved.id)

      %{pairing: elapsed_claimed, code: claimed_code, poll_secret: secret} = start_pairing()
      {:ok, _} = Machines.approve_pairing(user("select-claimed"), claimed_code)
      {:ok, _} = Machines.claim_pairing(elapsed_claimed.id, secret)
      close_window(elapsed_claimed.id)

      %{pairing: fresh} = start_pairing()

      selected = Machines.elapsed_pairing_ids(DateTime.utc_now())

      assert Enum.sort(selected) == Enum.sort([elapsed_pending.id, elapsed_approved.id])
      refute elapsed_claimed.id in selected
      refute fresh.id in selected
    end

    test "the predicate is served by machine_pairings_expires_at_index" do
      # A cold table is small enough that a sequential scan is the cheaper plan,
      # so the planner is asked which index it would use, not whether it bothers.
      # `SET LOCAL` so the choice dies with the sandbox's transaction and cannot
      # follow this connection back into the pool.
      Repo.query!("SET LOCAL enable_seqscan = off")

      # The production query itself, not a copy of it, so a predicate that stops
      # naming `expires_at` fails here as well as above.
      {sql, params} =
        Ecto.Adapters.SQL.to_sql(
          :all,
          Repo,
          Machines.elapsed_pairing_query(DateTime.utc_now())
        )

      plan =
        Repo.query!("EXPLAIN " <> sql, params).rows
        |> Enum.map_join("\n", &hd/1)

      assert plan =~ "machine_pairings_expires_at_index", plan
    end
  end

  # TokenVault carries exactly one AAD on the strength of this bound, and
  # CANON-002 states it as settled. It was not: nothing enforced it.
  test "no sealed ciphertext survives a closed window" do
    for key <- ["survivor-a", "survivor-b"] do
      %{pairing: pairing, code: code} = start_pairing()
      {:ok, _} = Machines.approve_pairing(user(key), code)
      close_window(pairing.id)
    end

    _swept = Machines.expire_elapsed_pairings()

    stale =
      Repo.all(
        from p in Pairing,
          where: not is_nil(p.token_ciphertext) and p.expires_at <= ^DateTime.utc_now(),
          select: p.token_ciphertext
      )

    assert stale == [],
           "sealed tokens outlived their window: #{inspect(Enum.map(stale, &TokenVault.open/1))}"
  end
end
