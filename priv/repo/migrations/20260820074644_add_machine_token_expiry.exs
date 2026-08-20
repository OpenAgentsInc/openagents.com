defmodule OpenAgents.Repo.Migrations.AddMachineTokenExpiry do
  use Ecto.Migration

  def up do
    alter table(:machines) do
      add :token_expires_at, :utc_datetime_usec
    end

    execute("UPDATE machines SET token_expires_at = NOW() + INTERVAL '30 days'")

    alter table(:machines) do
      modify :token_expires_at, :utc_datetime_usec, null: false
    end

    create constraint(:machines, :machines_token_expiry_after_creation,
             check: "token_expires_at > inserted_at"
           )
  end

  def down do
    drop_if_exists constraint(:machines, :machines_token_expiry_after_creation)

    alter table(:machines) do
      remove :token_expires_at
    end
  end
end
