defmodule OpenAgents.Notifications.Preference do
  @moduledoc """
  Per-account delivery categories.

  Four of the five default to on. A notification surface defaulted off delivers
  nothing to the people it exists for, and those four cannot reach a stranger:
  `issue_comments` and `issue_activity` reach only accounts that already opened,
  commented on, or were named in the issue, `mentions` reaches only an account
  someone addressed by name, and `assignments` reaches only the person the
  assignment names.

  `label_changes` is the exception and defaults off. A label moves for the
  benefit of a query, not of a reader, and it is addressed to nobody, so
  delivering it by default would spend the inbox's credibility on the least
  actionable event it carries.

  Each category names what it delivers, so turning one off has an effect you
  can predict from its name. That is why closing an issue is `issue_activity`
  rather than a quiet widening of `issue_comments`: somebody who switched off
  comments did not thereby ask to stop hearing that the issue closed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @categories ~w(mentions_enabled issue_comments_enabled assignments_enabled
                 issue_activity_enabled label_changes_enabled)a

  schema "notification_preferences" do
    field :mentions_enabled, :boolean, default: true
    field :issue_comments_enabled, :boolean, default: true
    field :assignments_enabled, :boolean, default: true
    field :issue_activity_enabled, :boolean, default: true
    field :label_changes_enabled, :boolean, default: false

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc "Every category this account can switch, in the order the form lists them."
  def categories, do: @categories

  @doc false
  def changeset(preference, attrs) do
    preference
    |> cast(attrs, @categories)
    |> validate_required(@categories)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end
end
