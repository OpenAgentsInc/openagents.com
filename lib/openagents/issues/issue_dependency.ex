defmodule OpenAgents.Issues.IssueDependency do
  @moduledoc """
  One prerequisite edge: `issue` cannot start until `blocked_by_issue` closes.

  The edge is the whole record. Whether an issue is blocked is never stored,
  because a stored flag goes stale the moment a prerequisite closes. Read it
  from the prerequisite's own state instead.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Repositories.Repository

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "issue_dependencies" do
    belongs_to :repository, Repository, type: :binary_id
    belongs_to :issue, Issue
    belongs_to :blocked_by_issue, Issue
    belongs_to :created_by_user, User, type: :binary_id
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(dependency, attrs) do
    dependency
    |> cast(attrs, [:repository_id, :issue_id, :blocked_by_issue_id, :created_by_user_id])
    |> validate_required([:repository_id, :issue_id, :blocked_by_issue_id])
    |> check_constraint(:blocked_by_issue_id,
      name: :issue_dependencies_no_self_reference,
      message: "cannot depend on itself"
    )
    |> unique_constraint([:issue_id, :blocked_by_issue_id])
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:blocked_by_issue_id)
  end
end
