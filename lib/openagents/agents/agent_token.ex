defmodule OpenAgents.Agents.AgentToken do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_tokens" do
    belongs_to :agent, OpenAgents.Agents.Agent
    field :name, :string
    field :token_digest, :binary, redact: true
    field :last_four, :string
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps()
  end

  def create_changeset(token, attrs) do
    token
    |> cast(attrs, [:name, :last_four, :scopes, :expires_at])
    |> validate_required([:name, :last_four, :scopes, :expires_at])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:last_four, is: 4)
    |> validate_length(:scopes, min: 1, max: 1)
    |> check_constraint(:scopes, name: :agent_tokens_scopes_present)
    |> check_constraint(:scopes, name: :agent_tokens_scopes_allowed)
    |> check_constraint(:expires_at, name: :agent_tokens_expiry_after_creation)
    |> check_constraint(:token_digest, name: :agent_tokens_digest_length)
  end
end
