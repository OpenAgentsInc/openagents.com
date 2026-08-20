defmodule OpenAgents.ProjectItems.ProjectItem do
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Repositories.Repository

  schema "project_items" do
    field :values, :map
    field :project_id, :id
    field :issue_id, :id
    belongs_to :repository, Repository, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(project_item, attrs) do
    project_item
    |> cast(attrs, [:values, :project_id, :issue_id, :repository_id])
    |> validate_required([:project_id, :issue_id, :repository_id])
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:project_id, name: :project_items_project_repository_fkey)
    |> foreign_key_constraint(:issue_id, name: :project_items_issue_repository_fkey)
  end
end
