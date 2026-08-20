defmodule OpenAgents.Issues.Issue do
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.Milestones.Milestone
  alias OpenAgents.Repositories.Repository

  schema "issues" do
    field :number, :integer
    field :title, :string
    field :body, :string
    field :state, :string, default: "open"
    field :state_reason, :string
    field :locked, :boolean, default: false
    field :locked_reason, :string
    field :closed_at, :utc_datetime
    field :comments, :integer, default: 0
    field :labels, {:array, :map}, default: []
    field :assignees, {:array, :map}, default: []
    field :milestone, :map
    field :user, :map
    belongs_to :repository, Repository, type: :binary_id
    belongs_to :milestone_record, Milestone, foreign_key: :milestone_id
    belongs_to :author_user, User, type: :binary_id
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [
      :number,
      :title,
      :body,
      :state,
      :state_reason,
      :locked,
      :locked_reason,
      :closed_at,
      :comments,
      :labels,
      :assignees,
      :milestone,
      :user,
      :repository_id,
      :milestone_id,
      :author_user_id
    ])
    |> validate_required([:title, :number, :repository_id])
    |> unique_constraint([:repository_id, :number])
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:milestone_id)
    |> foreign_key_constraint(:author_user_id)
  end
end
