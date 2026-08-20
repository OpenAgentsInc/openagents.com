defmodule OpenAgents.Repo.Migrations.CompleteVoiceSessionsColumns do
  use Ecto.Migration

  def up do
    alter table(:voice_sessions) do
      add_if_not_exists :role_selection, :map
    end
  end

  def down do
    alter table(:voice_sessions) do
      remove_if_exists :role_selection, :map
    end
  end
end
