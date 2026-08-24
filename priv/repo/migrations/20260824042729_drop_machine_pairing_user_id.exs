defmodule OpenAgents.Repo.Migrations.DropMachinePairingUserId do
  use Ecto.Migration

  @moduledoc """
  `machine_pairings.user_id` was written by `do_approve_pairing/4` and read by
  nothing. It is also strictly derivable: approval sets `user_id` and
  `machine_id` in one changeset, nothing sets either alone, and
  `machines.user_id` is the same account. See issue #184 and CANON-002.
  """

  def up do
    alter table(:machine_pairings) do
      remove :user_id
    end
  end

  def down do
    alter table(:machine_pairings) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
    end

    # The owner was never lost: it is the computer's owner, which is where the
    # column's only writer read it from in the first place.
    execute("""
    UPDATE machine_pairings AS p
       SET user_id = m.user_id
      FROM machines AS m
     WHERE m.id = p.machine_id
    """)
  end
end
