defmodule OpenAgents.Projects.ProjectItemEvent do
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.ProjectItems.ProjectItem
  alias OpenAgents.Projects.Project
  alias OpenAgents.Repositories.Repository

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "project_item_events" do
    belongs_to :project_item, ProjectItem, type: :id
    belongs_to :project, Project, type: :id
    belongs_to :repository, Repository, type: :binary_id
    belongs_to :actor_user, User, type: :binary_id
    field :actor_login, :string
    field :kind, :string
    field :from_state, :string
    field :to_state, :string
    field :changes, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :project_item_id,
      :project_id,
      :repository_id,
      :actor_user_id,
      :actor_login,
      :kind,
      :from_state,
      :to_state,
      :changes,
      :occurred_at
    ])
    |> validate_required([
      :project_item_id,
      :project_id,
      :repository_id,
      :actor_login,
      :kind,
      :occurred_at
    ])
    |> foreign_key_constraint(:project_item_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:actor_user_id)
  end
end
