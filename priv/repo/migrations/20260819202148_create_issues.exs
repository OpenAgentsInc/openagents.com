defmodule OpenAgents.Repo.Migrations.CreateIssues do
  use Ecto.Migration

  def change do
    create table(:issues) do
      add :number, :integer, null: false
      add :title, :string, null: false
      add :body, :text
      add :state, :string, default: "open"
      add :state_reason, :string
      add :locked, :boolean, default: false
      add :locked_reason, :string
      add :closed_at, :utc_datetime
      add :comments, :integer, default: 0
      add :labels, {:array, :map}, default: []
      add :assignees, {:array, :map}, default: []
      add :milestone, :map
      add :user, :map
      timestamps(type: :utc_datetime)
    end

    create unique_index(:issues, [:number])
  end
end
