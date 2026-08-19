defmodule OpenAgents.Repo.Migrations.CreateProjectItems do
  use Ecto.Migration

  def change do
    create table(:project_items) do
      add :values, :map
      add :project_id, references(:projects, on_delete: :nothing)
      add :issue_id, references(:issues, on_delete: :nothing)

      timestamps(type: :utc_datetime)
    end

    create index(:project_items, [:project_id])
    create index(:project_items, [:issue_id])
  end
end
