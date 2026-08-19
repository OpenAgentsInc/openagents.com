defmodule OpenAgents.Accounts.OAuthAttempt do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "github_oauth_attempts" do
    field :state_digest, :binary
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec

    timestamps()
  end

  def create_changeset(attempt, attributes) do
    attempt
    |> cast(attributes, [:state_digest, :expires_at])
    |> validate_required([:state_digest, :expires_at])
    |> unique_constraint(:state_digest)
  end
end
