defmodule OpenAgents.Repo.Migrations.CreateProjectFields do
  use Ecto.Migration

  def change do
    create table(:project_fields) do
      add :name, :string
      add :data_type, :string
      add :options, :map
      add :project_id, references(:projects, on_delete: :nothing)

      timestamps(type: :utc_datetime)
    end

    create index(:project_fields, [:project_id])
  end
end
