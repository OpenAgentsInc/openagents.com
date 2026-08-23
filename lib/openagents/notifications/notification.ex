defmodule OpenAgents.Notifications.Notification do
  @moduledoc """
  One durable delivery record addressed to one account.

  It is a pointer, not a copy. Nothing here renders without a second read of
  the issue through the recipient's own visibility, so a row that outlives the
  recipient's access to the repository reveals nothing.

  Seven kinds. `mention` and `issue_comment` announce something somebody wrote.
  `assigned`, `unassigned`, `labeled`, `unlabeled` and `state_changed` announce
  a change to the issue itself, derived from the difference between the issue
  before and after an update. The record still names no label and no state: the
  kind says which field moved, and reading the issue says what it moved to.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.Issues.Comment
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Repositories.Repository

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(mention issue_comment assigned unassigned labeled unlabeled state_changed)

  schema "notifications" do
    field :kind, :string
    field :actor_login, :string
    field :dedupe_key, :string
    field :read_at, :utc_datetime

    belongs_to :user, User
    belongs_to :repository, Repository
    belongs_to :issue, Issue, type: :id
    belongs_to :comment, Comment, type: :id

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  @doc false
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:kind, :actor_login, :dedupe_key, :read_at])
    |> validate_required([:kind, :dedupe_key])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:user_id, :dedupe_key])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:comment_id)
  end
end
