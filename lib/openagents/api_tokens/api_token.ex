defmodule OpenAgents.ApiTokens.ApiToken do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "api_tokens" do
    belongs_to :user, OpenAgents.Accounts.User
    field :name, :string
    field :token_digest, :binary, redact: true
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{}

  def create_changeset(token, attributes) do
    token
    |> cast(attributes, [:name, :scopes, :expires_at])
    |> validate_required([:name, :scopes, :expires_at])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:scopes, min: 1, max: 8)
    |> check_constraint(:scopes, name: :api_tokens_scopes_present)
    |> check_constraint(:scopes, name: :api_tokens_scopes_allowed)
    |> check_constraint(:expires_at, name: :api_tokens_expiry_after_creation)
    |> check_constraint(:token_digest, name: :api_tokens_digest_length)
  end
end
