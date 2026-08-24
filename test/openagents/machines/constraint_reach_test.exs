defmodule OpenAgents.Machines.ConstraintReachTest do
  @moduledoc """
  Issue #184 lists five PostgreSQL constraints on the computer tables with no
  `check_constraint/2` or `unique_constraint/2` beside them, so a violation
  arrives as a `Postgrex.Error` rather than an invalid changeset.

  That is a defect when a user-supplied value can reach the constraint: a form
  should have refused the input, and instead the request 500s. None of these
  five can be reached that way, so each is recorded here rather than mapped —
  and recorded as an assertion, because the reason it cannot be reached is a
  property of the code that can change.

  | Constraint | Guarded by |
  | --- | --- |
  | `machines_status_check` | `status` is not cast; writers pass literals |
  | `machine_pairings_status_check` | same |
  | `machines_token_expiry_after_creation` | `token_expires_at` is not cast, and its TTL is admitted at boot |
  | `machines_token_digest_index` | 256 random bits, not user input |
  | `machine_pairings_code_digest_index` | a random code, not user input |

  The constraints stay. They are the last defense against a future writer, and
  the tests below show each one still refusing a bad row when reached directly.
  Mapping them would claim a population that cannot occur.
  """

  use OpenAgents.DataCase, async: true

  alias OpenAgents.Machines
  alias OpenAgents.Machines.{Machine, Pairing}
  alias OpenAgents.Repo
  alias OpenAgents.RuntimeConfig

  # Everything an attacker controls on the two unauthenticated or
  # owner-facing write paths, plus every field the constraints guard.
  @hostile %{
    "name" => "box",
    "tier" => "probe",
    "status" => "compromised",
    "token_digest" => "chosen",
    "token_expires_at" => ~U[1970-01-01 00:00:00.000000Z],
    "revoked_at" => ~U[1970-01-01 00:00:00.000000Z],
    "code_digest" => "chosen",
    "poll_secret_digest" => "chosen",
    "expires_at" => ~U[1970-01-01 00:00:00.000000Z],
    "user_id" => Ecto.UUID.generate(),
    "machine_id" => Ecto.UUID.generate()
  }

  @guarded ~w(status token_digest token_expires_at code_digest expires_at)a

  describe "no user-supplied value reaches the guarded columns" do
    test "the computer changeset casts none of them" do
      changes = Machine.create_changeset(%Machine{}, @hostile).changes

      for field <- @guarded do
        refute Map.has_key?(changes, field),
               "#{field} became castable; it now reaches a constraint with no changeset mapping"
      end
    end

    test "the pairing changeset casts none of them" do
      changes = Pairing.create_changeset(%Pairing{}, @hostile).changes

      for field <- @guarded do
        refute Map.has_key?(changes, field),
               "#{field} became castable; it now reaches a constraint with no changeset mapping"
      end
    end

    test "a hostile pairing request still produces an ordinary pending row" do
      # The unauthenticated entry point, carrying the whole hostile map.
      assert {:ok, %{pairing: pairing}} = Machines.start_pairing(@hostile)

      assert pairing.status == "pending"
      assert pairing.code_digest != "chosen"
      assert DateTime.compare(pairing.expires_at, DateTime.utc_now()) == :gt
    end
  end

  describe "machines_token_expiry_after_creation is guarded before boot, not at insert" do
    test "the admitted TTL range cannot produce a row the constraint refuses" do
      settings = Application.get_all_env(:openagents)

      for ttl <- [0, -1, -86_400] do
        assert {:error, _reason} =
                 RuntimeConfig.validate(Keyword.put(settings, :machine_token_ttl_seconds, ttl)),
               "a TTL of #{ttl} would make every pairing approval raise, and boot admitted it"
      end

      assert {:ok, _config} =
               RuntimeConfig.validate(Keyword.put(settings, :machine_token_ttl_seconds, 300))
    end
  end

  describe "the constraints are still load-bearing" do
    test "machines_status_check refuses a status reached around the changeset" do
      owner = owner()

      assert_raise Postgrex.Error, ~r/machines_status_check/, fn ->
        Repo.query!(
          """
          INSERT INTO machines
            (id, user_id, name, tier, roots, token_digest, token_expires_at, status,
             scoped_forge_credentials_enabled, inserted_at, updated_at)
          VALUES (gen_random_uuid(), $1, 'x', 'probe', '{}', 'd', NOW() + INTERVAL '1 day',
                  'compromised', false, NOW(), NOW())
          """,
          [Ecto.UUID.dump!(owner.id)]
        )
      end
    end

    test "machines_token_expiry_after_creation refuses an expiry before creation" do
      owner = owner()

      assert_raise Postgrex.Error, ~r/machines_token_expiry_after_creation/, fn ->
        Repo.query!(
          """
          INSERT INTO machines
            (id, user_id, name, tier, roots, token_digest, token_expires_at, status,
             scoped_forge_credentials_enabled, inserted_at, updated_at)
          VALUES (gen_random_uuid(), $1, 'x', 'probe', '{}', 'd', NOW() - INTERVAL '1 day',
                  'active', false, NOW(), NOW())
          """,
          [Ecto.UUID.dump!(owner.id)]
        )
      end
    end

    test "machine_pairings_status_check refuses a status reached around the changeset" do
      assert_raise Postgrex.Error, ~r/machine_pairings_status_check/, fn ->
        Repo.query!(
          """
          INSERT INTO machine_pairings
            (id, code_digest, poll_secret_digest, name, tier, roots, status, expires_at,
             inserted_at, updated_at)
          VALUES (gen_random_uuid(), 'a', 'b', 'x', 'probe', '{}', 'compromised',
                  NOW() + INTERVAL '1 hour', NOW(), NOW())
          """,
          []
        )
      end
    end

    test "machine_pairings_code_digest_index refuses a duplicate code" do
      %{pairing: first} = start_pairing()
      digest = Repo.get!(Pairing, first.id).code_digest

      assert_raise Postgrex.Error, ~r/machine_pairings_code_digest_index/, fn ->
        Repo.query!(
          """
          INSERT INTO machine_pairings
            (id, code_digest, poll_secret_digest, name, tier, roots, status, expires_at,
             inserted_at, updated_at)
          VALUES (gen_random_uuid(), $1, 'b', 'x', 'probe', '{}', 'pending',
                  NOW() + INTERVAL '1 hour', NOW(), NOW())
          """,
          [digest]
        )
      end
    end

    test "machines_token_digest_index refuses a duplicate computer token" do
      owner = owner()
      %{code: code} = start_pairing()
      {:ok, machine} = Machines.approve_pairing(owner, code)
      digest = Repo.get!(Machine, machine.id).token_digest

      assert_raise Postgrex.Error, ~r/machines_token_digest_index/, fn ->
        Repo.query!(
          """
          INSERT INTO machines
            (id, user_id, name, tier, roots, token_digest, token_expires_at, status,
             scoped_forge_credentials_enabled, inserted_at, updated_at)
          VALUES (gen_random_uuid(), $1, 'x', 'probe', '{}', $2, NOW() + INTERVAL '1 day',
                  'active', false, NOW(), NOW())
          """,
          [Ecto.UUID.dump!(owner.id), digest]
        )
      end
    end
  end

  defp owner do
    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: :erlang.phash2({__MODULE__, System.unique_integer()}),
        github_login: "reach-#{System.unique_integer([:positive])}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    user
  end

  defp start_pairing do
    {:ok, started} = Machines.start_pairing(%{"name" => "box", "tier" => "probe"})
    started
  end
end
