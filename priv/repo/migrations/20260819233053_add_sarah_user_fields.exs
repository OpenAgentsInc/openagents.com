defmodule OpenAgents.Repo.Migrations.AddSarahUserFields do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :public_leaderboard_opted_out, :boolean, null: false, default: false
      add :browser_key_hash, :binary
    end

    create unique_index(:users, [:browser_key_hash], where: "browser_key_hash IS NOT NULL")

    create constraint(:users, :users_status_check, check: "status IN ('active', 'banned')")

    create constraint(:users, :users_ban_state_check,
             check:
               "(status = 'active' AND banned_at IS NULL AND ban_reason_code IS NULL) OR " <>
                 "(status = 'banned' AND banned_at IS NOT NULL)"
           )
  end
end
