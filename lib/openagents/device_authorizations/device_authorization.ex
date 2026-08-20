defmodule OpenAgents.DeviceAuthorizations.DeviceAuthorization do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "device_authorizations" do
    field :device_code_digest, :binary
    field :user_code_digest, :binary
    field :state, :string, default: "pending"
    field :scopes, {:array, :string}, default: ["forge:write"]
    field :interval_seconds, :integer, default: 5
    field :poll_count, :integer, default: 0
    field :last_polled_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec
    field :denied_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec

    belongs_to :user, OpenAgents.Accounts.User
    belongs_to :api_token, OpenAgents.ApiTokens.ApiToken

    timestamps()
  end

  def create_changeset(authorization, attrs) do
    authorization
    |> cast(attrs, [
      :device_code_digest,
      :user_code_digest,
      :expires_at,
      :interval_seconds
    ])
    |> put_change(:state, "pending")
    |> put_change(:scopes, ["forge:write"])
    |> validate_required([
      :device_code_digest,
      :user_code_digest,
      :state,
      :scopes,
      :expires_at,
      :interval_seconds
    ])
    |> validate_number(:interval_seconds, greater_than_or_equal_to: 1, less_than_or_equal_to: 30)
    |> unique_constraint(:device_code_digest)
    |> unique_constraint(:user_code_digest)
    |> check_constraint(:state, name: :device_authorizations_state_check)
    |> check_constraint(:interval_seconds, name: :device_authorizations_interval_check)
  end
end
