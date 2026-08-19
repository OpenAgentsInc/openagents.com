defmodule OpenAgents.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :number, :integer
      add :title, :string
      add :owner, :string
      add :state, :string

      timestamps(type: :utc_datetime)
    end
  end
end
