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

    # Not a column: resolved once by `UserAuth.on_mount/4` when it builds the
    # scope, because the sidebar asks on every render and the answer must not
    # be a query each time. Defaults to false, so a user loaded by any other
    # path is treated as new rather than accidentally grandfathered.
    field :agent_surfaces?, :boolean, virtual: true, default: false

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
          agent_surfaces?: boolean(),
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
