defmodule OpenAgents.Milestones.Milestone do
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Repositories.Repository

  schema "milestones" do
    field :title, :string
    field :state, :string, default: "open"
    field :description, :string
    field :due_on, :string
    field :number, :integer
    field :open_issues, :integer, virtual: true, default: 0
    field :closed_issues, :integer, virtual: true, default: 0
    belongs_to :repository, Repository, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(milestone, attrs) do
    milestone
    |> cast(attrs, [:title, :state, :description, :due_on, :number, :repository_id])
    |> validate_required([:title, :number, :repository_id])
    |> unique_constraint([:repository_id, :number])
    |> foreign_key_constraint(:repository_id)
  end
end
