defmodule OpenAgents.Notifications.Preference do
  @moduledoc """
  Per-account delivery categories.

  Both categories default to on. A notification surface defaulted off delivers
  nothing to the people it exists for, and neither category can reach a
  stranger: `issue_comments` reaches only accounts that already opened,
  commented on, or were named in the issue, and `mentions` reaches only an
  account someone addressed by name.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "notification_preferences" do
    field :mentions_enabled, :boolean, default: true
    field :issue_comments_enabled, :boolean, default: true

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [:mentions_enabled, :issue_comments_enabled])
    |> validate_required([:mentions_enabled, :issue_comments_enabled])
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end
end
