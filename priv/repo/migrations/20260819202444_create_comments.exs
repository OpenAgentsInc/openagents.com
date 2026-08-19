defmodule OpenAgents.Repo.Migrations.CreateComments do
  use Ecto.Migration

  def change do
    create table(:comments) do
      add :body, :text
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :user, :map
      add :created_at, :utc_datetime
      add :updated_at, :utc_datetime
    end
  end
end
