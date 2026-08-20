defmodule OpenAgents.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Repositories.Repository

  schema "projects" do
    field :number, :integer
    field :title, :string
    field :owner, :string
    field :state, :string, default: "open"
    belongs_to :repository, Repository, type: :binary_id
    belongs_to :owner_user, OpenAgents.Accounts.User, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:number, :title, :owner, :state, :repository_id, :owner_user_id])
    |> validate_required([:number, :title, :owner, :state, :repository_id])
    |> unique_constraint([:repository_id, :number])
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:owner_user_id)
    |> foreign_key_constraint(:owner_user_id, name: :projects_owner_membership_fkey)
  end
end
