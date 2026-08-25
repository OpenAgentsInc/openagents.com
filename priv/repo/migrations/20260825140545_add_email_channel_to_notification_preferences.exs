defmodule OpenAgents.Repo.Migrations.AddEmailChannelToNotificationPreferences do
  @moduledoc """
  The second delivery channel, off for every account that already exists.

  The five columns beside this one are categories: what an account hears about.
  This one is a channel: where it hears about it. In-product delivery has no
  switch because it is the inbox itself; email does, and it defaults to false.

  Turning a channel on for every existing account without asking would mail
  people who chose the inbox and nothing else, so `false` is the only honest
  backfill. `NOT NULL DEFAULT false` fills the existing rows in place, and a
  node running the previous release neither reads nor writes the column.
  """

  use Ecto.Migration

  def change do
    alter table(:notification_preferences) do
      add :email_enabled, :boolean, null: false, default: false
    end
  end
end
