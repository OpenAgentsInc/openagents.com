defmodule OpenAgents.Notifications.IssueSubscription do
  @moduledoc """
  One person's standing interest in one issue.

  `subscribed` is false for an explicit mute, which is why muting keeps the row
  instead of deleting it: taking part again must not undo a decision the person
  already made.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Repositories.Repository

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @reasons ~w(author commented mentioned manual)

  schema "issue_subscriptions" do
    field :reason, :string
    field :subscribed, :boolean, default: true

    belongs_to :issue, Issue, type: :id
    belongs_to :repository, Repository
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def reasons, do: @reasons

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:reason, :subscribed])
    |> validate_required([:reason, :subscribed])
    |> validate_inclusion(:reason, @reasons)
    |> unique_constraint([:issue_id, :user_id])
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:user_id)
  end
end
