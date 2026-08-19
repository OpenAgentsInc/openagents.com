defmodule OpenAgents.Repo.Migrations.CreateMilestones do
  use Ecto.Migration

  def change do
    create table(:milestones) do
      add :title, :string
      add :state, :string
      add :description, :string
      add :due_on, :string
      add :number, :integer

      timestamps(type: :utc_datetime)
    end
  end
end
