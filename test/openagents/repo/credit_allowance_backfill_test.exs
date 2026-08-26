defmodule OpenAgents.Repo.CreditAllowanceBackfillTest do
  @moduledoc """
  The migration that moved the account allowance onto `users`, run for real.

  Everything else about this change is safe to get wrong twice. This is not:
  the allowance went from $100 for every account to $20 for a new one, and a
  migration that wrote the new figure across the rows that already existed
  would have silently re-priced every live account and put any that had metered
  more than $20 out of credit in the same deploy.

  So the backfill is not asserted here, it is executed. The migration is rolled
  back so the rows under test are genuinely pre-migration rows — the column does
  not exist while they sit there — and then run forward again. What the test
  reads afterwards is what the migration wrote.

  It runs inside the sandbox transaction the case checks out. PostgreSQL makes
  DDL transactional, so the column disappearing and reappearing is invisible to
  every other connection and is rolled back with the rest of the test.
  """

  use OpenAgents.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias OpenAgents.Repo.Migrations.GrantNewAccountsTwentyDollarsOfCredit, as: Migration

  @version 20_260_826_145_554

  # Migrations are not on the compile path, so the module is loaded from the
  # file the repository will actually run. Found by its version rather than by
  # a hard-coded name, so renaming the file fails this test instead of quietly
  # leaving it testing nothing.
  setup_all do
    [path] = Path.wildcard("priv/repo/migrations/#{@version}_*.exs")
    Code.require_file(path)
    :ok
  end

  # $100. Written out rather than read from the migration, because a test that
  # asks the code under test what the right answer is proves only that it is
  # self-consistent.
  @existing_account_microusd 100_000_000

  # $20, the figure config carries for a new account.
  @new_account_microusd 20_000_000

  defp insert_user(login) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO users
        (id, github_id, github_login, github_avatar_url, status, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'active', NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(id),
        :erlang.phash2(login, 1_000_000) + 1,
        login,
        "https://avatars.githubusercontent.com/u/1?v=4"
      ]
    )

    id
  end

  defp allowance_of(id) do
    %{rows: [[allowance]]} =
      SQL.query!(
        Repo,
        "SELECT credit_allowance_microusd FROM users WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    allowance
  end

  defp column_exists? do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        """
        SELECT COUNT(*) FROM information_schema.columns
         WHERE table_name = 'users' AND column_name = 'credit_allowance_microusd'
        """,
        []
      )

    count == 1
  end

  test "every account that existed before the migration keeps $100" do
    veterans = Enum.map(1..3, &insert_user("veteran-#{&1}"))

    # Down first: the rows above become rows from before this change existed,
    # with no allowance recorded anywhere, which is the only state the backfill
    # is claimed to handle.
    :ok = Ecto.Migrator.down(Repo, @version, Migration, log: false, migration_lock: false)
    refute column_exists?()

    :ok = Ecto.Migrator.up(Repo, @version, Migration, log: false, migration_lock: false)
    assert column_exists?()

    for id <- veterans do
      assert allowance_of(id) == @existing_account_microusd
    end
  end

  test "an account created after the migration is granted $20" do
    :ok = Ecto.Migrator.down(Repo, @version, Migration, log: false, migration_lock: false)
    :ok = Ecto.Migrator.up(Repo, @version, Migration, log: false, migration_lock: false)

    # Inserted through raw SQL, so the figure comes from the column default the
    # migration installed rather than from anything the application chose.
    fresh = insert_user("post-migration")

    assert allowance_of(fresh) == @new_account_microusd
  end

  test "the migration does not lower an account that already holds $100" do
    # The realistic double-run: a deploy that migrates, an account that keeps
    # its grandfathered figure, and a rollback-and-forward afterwards. The
    # second pass must not treat $100 as a value to overwrite — it writes only
    # where nothing is recorded.
    veteran = insert_user("twice-migrated")

    :ok = Ecto.Migrator.down(Repo, @version, Migration, log: false, migration_lock: false)
    :ok = Ecto.Migrator.up(Repo, @version, Migration, log: false, migration_lock: false)
    assert allowance_of(veteran) == @existing_account_microusd

    :ok = Ecto.Migrator.down(Repo, @version, Migration, log: false, migration_lock: false)
    :ok = Ecto.Migrator.up(Repo, @version, Migration, log: false, migration_lock: false)
    assert allowance_of(veteran) == @existing_account_microusd
  end

  test "an allowance cannot be driven below zero" do
    veteran = insert_user("floor")

    assert_raise Postgrex.Error, fn ->
      SQL.query!(
        Repo,
        "UPDATE users SET credit_allowance_microusd = -1 WHERE id = $1",
        [Ecto.UUID.dump!(veteran)]
      )
    end
  end
end
