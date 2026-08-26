defmodule OpenAgents.Accounts.User do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "users" do
    field :github_id, :integer
    field :github_login, :string
    field :github_name, :string
    field :github_avatar_url, :string
    field :status, :string, default: "active"
    field :banned_at, :utc_datetime_usec
    field :ban_reason_code, :string
    field :last_authenticated_at, :utc_datetime_usec
    field :github_token_ciphertext, :binary, redact: true
    field :github_token_key_id, :string
    field :github_token_scopes, {:array, :string}, default: []
    field :github_token_connected_at, :utc_datetime_usec
    field :github_token_rotated_at, :utc_datetime_usec
    field :public_leaderboard_opted_out, :boolean, default: false
    field :browser_key_hash, :binary

    # The inference money this account holds, in microUSD. It is on the account
    # rather than in config because the two are not the same question: config
    # says what a new account is granted, and this says what this one holds.
    # An account created when the grant was $100 still holds $100 after the
    # grant became $20, and a later top-up is a write here rather than a new
    # subsystem.
    #
    # Only the allowance is here. Spend is still summed from the grants' own
    # `usage` by `OpenAgents.Inference.Credit.spent/1`, so this column can
    # never disagree with a spend counter — there is no spend counter.
    field :credit_allowance_microusd, :integer

    # The notification channel's address, and the proof its owner asked for it.
    # Nothing reads `notification_email` as a recipient on its own:
    # `OpenAgents.Notifications.EmailChannel.verified_address/1` is the one
    # read, and it returns `nil` while `notification_email_verified_at` is,
    # so an address typed but never confirmed is inert. The code is held as a
    # SHA-256 digest, never as plaintext.
    field :notification_email, :string
    field :notification_email_verified_at, :utc_datetime_usec
    field :notification_email_code_digest, :binary, redact: true
    field :notification_email_code_sent_at, :utc_datetime_usec
    field :notification_email_code_attempts, :integer, default: 0

    # Not a column: resolved once by `UserAuth.on_mount/4` when it builds the
    # scope, because the sidebar asks on every render and the answer must not
    # be a query each time. Defaults to false, so a user loaded by any other
    # path is treated as new rather than accidentally grandfathered.
    field :agent_surfaces?, :boolean, virtual: true, default: false

    # Also not a column, and also carried by the scope for the sidebar. It is
    # the one number on that surface that changes without navigation, so unlike
    # `agent_surfaces?` it is refreshed in place: `UserAuth.on_mount/4`
    # recounts it when `OpenAgents.Notifications` says this account's inbox
    # moved. Defaults to zero, so a user loaded by any other path shows no
    # badge rather than a stale one.
    field :unread_notifications, :integer, virtual: true, default: 0

    has_one :storage_owner, OpenAgents.Conversations.Visitor

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          github_id: pos_integer(),
          github_login: String.t(),
          github_name: String.t() | nil,
          github_avatar_url: String.t(),
          status: String.t(),
          banned_at: DateTime.t() | nil,
          ban_reason_code: String.t() | nil,
          last_authenticated_at: DateTime.t() | nil,
          github_token_ciphertext: binary() | nil,
          github_token_key_id: String.t() | nil,
          github_token_scopes: [String.t()],
          github_token_connected_at: DateTime.t() | nil,
          github_token_rotated_at: DateTime.t() | nil,
          public_leaderboard_opted_out: boolean(),
          browser_key_hash: binary() | nil,
          credit_allowance_microusd: non_neg_integer(),
          notification_email: String.t() | nil,
          notification_email_verified_at: DateTime.t() | nil,
          notification_email_code_digest: binary() | nil,
          notification_email_code_sent_at: DateTime.t() | nil,
          notification_email_code_attempts: non_neg_integer(),
          agent_surfaces?: boolean(),
          unread_notifications: non_neg_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  def github_changeset(user, attributes) do
    user
    |> cast(attributes, [
      :github_id,
      :github_login,
      :github_name,
      :github_avatar_url,
      :last_authenticated_at
    ])
    |> validate_required([
      :github_id,
      :github_login,
      :github_avatar_url,
      :last_authenticated_at
    ])
    |> validate_number(:github_id, greater_than: 0)
    |> validate_length(:github_login, min: 1, max: 39)
    |> validate_length(:github_name, max: 255)
    |> validate_format(:github_login, ~r/\A[A-Za-z0-9][A-Za-z0-9-]*\z/)
    |> validate_avatar_url()
    |> unique_constraint(:github_id)
  end

  def leaderboard_changeset(user, opted_out?) when is_boolean(opted_out?) do
    user
    |> cast(%{public_leaderboard_opted_out: opted_out?}, [:public_leaderboard_opted_out])
    |> validate_required([:public_leaderboard_opted_out])
  end

  def ban_changeset(user, reason_code) do
    user
    |> cast(
      %{
        status: "banned",
        banned_at: DateTime.utc_now(),
        ban_reason_code: reason_code
      },
      [:status, :banned_at, :ban_reason_code]
    )
    |> validate_required([:status, :banned_at])
    |> validate_length(:ban_reason_code, max: 80)
    |> check_constraint(:status, name: :users_status_check)
    |> check_constraint(:status, name: :users_ban_state_check)
  end

  defp validate_avatar_url(changeset) do
    validate_change(changeset, :github_avatar_url, fn :github_avatar_url, value ->
      case URI.new(value) do
        {:ok, %URI{scheme: "https", host: "avatars.githubusercontent.com"}} ->
          []

        _invalid ->
          [github_avatar_url: "must be an HTTPS GitHub avatar URL"]
      end
    end)
  end
end
