defmodule OpenAgents.Issues.Comment do
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Issues.Issue
  alias OpenAgents.Agents.Agent
  alias OpenAgents.Repositories.Repository

  schema "comments" do
    field :body, :string
    field :user, :map
    field :created_at, :utc_datetime
    field :updated_at, :utc_datetime

    belongs_to :issue, Issue
    belongs_to :repository, Repository, type: :binary_id
    belongs_to :author_user, OpenAgents.Accounts.User, type: :binary_id
    belongs_to :author_agent, Agent, type: :binary_id
  end

  @doc false
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [
      :body,
      :user,
      :issue_id,
      :repository_id,
      :author_user_id,
      :author_agent_id,
      :created_at,
      :updated_at
    ])
    |> validate_required([:body, :issue_id, :repository_id, :created_at, :updated_at])
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:author_user_id)
    |> foreign_key_constraint(:author_agent_id)
    |> foreign_key_constraint(:issue_id, name: :comments_issue_repository_fkey)
  end
end
