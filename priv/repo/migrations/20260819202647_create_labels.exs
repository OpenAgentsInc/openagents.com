defmodule OpenAgents.Repo.Migrations.CreateLabels do
  use Ecto.Migration

  def change do
    create table(:labels) do
      add :name, :string
      add :color, :string
      add :description, :string

      timestamps(type: :utc_datetime)
    end
  end
end
