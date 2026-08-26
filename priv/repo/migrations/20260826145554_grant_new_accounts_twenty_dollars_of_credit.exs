defmodule OpenAgents.Repo.Migrations.GrantNewAccountsTwentyDollarsOfCredit do
  use Ecto.Migration

  @moduledoc """
  Move the account inference allowance from a config constant onto the account.

  The allowance used to be `account_credit_microusd`, read per request for
  every signed-in account alike. That constant cannot tell a new account from
  an existing one, so lowering it to $20 would not have granted new users $20 —
  it would have re-priced every account that already held $100, and put any
  account that had already metered more than $20 out of credit in the same
  deploy.

  So the figure moves onto `users`. The config constant stays as the default a
  new row is created with, and this column is the truth for an account that
  exists. Nothing else about the credit changes: spend is still summed from the
  grants' own `usage`, so there is still no second counter to disagree with a
  ledger.

  The backfill is the part worth reading. Every row that exists when this runs
  is by definition an existing account, and the decision is that existing
  accounts keep $100 — so the column is added nullable, every existing row is
  written to 100_000_000 explicitly, and only then does it become `NOT NULL`
  with the new-account default. Adding it with the default in one step would
  have written $20 across every existing account, which is the one outcome this
  change must not produce.
  """

  # $100, the allowance every account held before this migration ran.
  @existing_account_microusd 100_000_000

  # $20, the allowance a row created after this migration is granted. It
  # matches `:account_credit_microusd` in config, which is what
  # `OpenAgents.Inference.Credit.new_account_allowance/0` reads at insert time.
  # This default is the database's backstop for a row inserted by some other
  # path, not a second source of the figure.
  @new_account_microusd 20_000_000

  def up do
    alter table(:users) do
      add :credit_allowance_microusd, :bigint
    end

    execute("""
    UPDATE users
       SET credit_allowance_microusd = #{@existing_account_microusd}
     WHERE credit_allowance_microusd IS NULL
    """)

    alter table(:users) do
      modify :credit_allowance_microusd, :bigint,
        null: false,
        default: @new_account_microusd
    end

    create constraint(:users, :users_credit_allowance_nonnegative,
             check: "credit_allowance_microusd >= 0"
           )
  end

  def down do
    drop constraint(:users, :users_credit_allowance_nonnegative)

    alter table(:users) do
      remove :credit_allowance_microusd
    end
  end
end
