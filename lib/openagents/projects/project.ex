defmodule OpenAgents.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Repositories.Repository

  @states ~w(open closed)

  @doc "The states a project moves between."
  def states, do: @states

  schema "projects" do
    field :number, :integer
    field :title, :string
    field :description, :string
    field :owner, :string
    field :state, :string, default: "open"
    field :archived_at, :utc_datetime
    belongs_to :repository, Repository, type: :binary_id
    belongs_to :owner_user, OpenAgents.Accounts.User, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Whether `project` sits in the archive.

  Archiving is orthogonal to `state`. A closed project says the work it tracked
  reached an end; an archived project says the board is out of the working set,
  whatever became of the work. That is why the archive is a timestamp rather
  than a third `state` value: every reader of `open` and `closed` keeps reading
  the two values it always read.
  """
  def archived?(%__MODULE__{archived_at: nil}), do: false
  def archived?(%__MODULE__{}), do: true

  @doc false
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :number,
      :title,
      :description,
      :owner,
      :state,
      :archived_at,
      :repository_id,
      :owner_user_id
    ])
    |> validate_required([:number, :title, :owner, :state, :repository_id])
    |> validate_inclusion(:state, @states)
    |> validate_length(:description, max: 20_000)
    |> unique_constraint([:repository_id, :number])
    |> check_constraint(:state, name: :projects_state_check, message: "is invalid")
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:owner_user_id)
    |> foreign_key_constraint(:owner_user_id, name: :projects_owner_membership_fkey)
  end
end
