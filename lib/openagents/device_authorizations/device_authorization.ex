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
    field :device_name, :string
    field :kind, :string, default: "token"
    field :state, :string, default: "pending"
    field :scopes, {:array, :string}, default: ["chat:account", "forge:write"]
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
      :device_name,
      :kind,
      :expires_at,
      :interval_seconds,
      :scopes
    ])
    |> put_change(:state, "pending")
    |> validate_kind()
    |> validate_scopes()
    |> validate_required([
      :device_code_digest,
      :user_code_digest,
      :state,
      :scopes,
      :expires_at,
      :interval_seconds
    ])
    |> validate_number(:interval_seconds, greater_than_or_equal_to: 1, less_than_or_equal_to: 30)
    |> validate_length(:device_name, max: 80)
    |> unique_constraint(:device_code_digest)
    |> unique_constraint(:user_code_digest)
    |> check_constraint(:state, name: :device_authorizations_state_check)
    |> check_constraint(:interval_seconds, name: :device_authorizations_interval_check)
  end

  # A connect authorization is not a credential request: its marker scope is
  # what the approval page shows, and the token endpoint must never mint from
  # it. The two kinds keep disjoint scope sets, so one row can never be both.
  defp validate_kind(changeset) do
    case get_field(changeset, :kind) do
      "github_connect" ->
        put_change(changeset, :scopes, ["github:connect"])

      kind when kind in [nil, "token"] ->
        put_change(changeset, :kind, "token")

      _other ->
        add_error(changeset, :kind, "is not an allowed kind")
    end
  end

  # The requested scopes are shown to the approver, so they must be real
  # scopes rather than free text. Nothing here decides whether this person may
  # grant them; `OpenAgents.DeviceAuthorizations.approve/2` does that.
  defp validate_scopes(changeset) do
    allowed = OpenAgents.ApiTokens.allowed_scopes()

    case get_field(changeset, :kind) do
      "github_connect" ->
        changeset

      _token_kind ->
        case get_field(changeset, :scopes) do
          scopes when is_list(scopes) and scopes != [] ->
            if Enum.all?(scopes, &(&1 in allowed)),
              do: put_change(changeset, :scopes, Enum.uniq(scopes)),
              else: add_error(changeset, :scopes, "is not an allowed scope set")

          _empty ->
            put_change(changeset, :scopes, OpenAgents.ApiTokens.default_scopes())
        end
    end
  end
end
