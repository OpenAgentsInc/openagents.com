defmodule OpenAgents.ProjectItems.ProjectItem do
  use Ecto.Schema
  import Ecto.Changeset

  schema "project_items" do
    field :values, :map
    field :project_id, :id
    field :issue_id, :id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(project_item, attrs) do
    project_item
    |> cast(attrs, [:values, :project_id, :issue_id])
    |> validate_required([:project_id, :issue_id])
  end
end
