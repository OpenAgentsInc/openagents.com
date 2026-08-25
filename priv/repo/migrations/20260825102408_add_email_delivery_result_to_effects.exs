defmodule OpenAgents.Repo.Migrations.AddEmailDeliveryResultToEffects do
  use Ecto.Migration

  def change do
    alter table(:effects) do
      add :result, :map
    end
  end
end
