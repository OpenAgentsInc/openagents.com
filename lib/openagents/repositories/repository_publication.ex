defmodule OpenAgents.Repositories.RepositoryPublication do
  @moduledoc "Records one idempotent publication from a chat workspace to Forge."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  @states ~w(requested committing pushing accepted uncertain failed nothing_to_publish)

  schema "repository_publications" do
    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :owner_user, OpenAgents.Accounts.User
    field :conversation_id, :binary_id
    field :tool_call_id, :string
    field :workspace_ref, :string
    field :idempotency_key, :string
    field :argument_digest, :string
    field :message, :string
    field :expected_workspace_digest, :string
    field :observed_workspace_digest, :string
    field :branch, :string
    field :source_oid, :string
    field :expected_previous_oid, :string
    field :published_oid, :string
    field :state, :string, default: "requested"
    field :wal_seq, :integer
    field :result, :map
    field :error_code, :string
    timestamps()
  end

  def changeset(publication, attrs) do
    publication
    |> cast(attrs, [
      :repository_id,
      :owner_user_id,
      :conversation_id,
      :tool_call_id,
      :workspace_ref,
      :idempotency_key,
      :argument_digest,
      :message,
      :expected_workspace_digest,
      :observed_workspace_digest,
      :branch,
      :source_oid,
      :expected_previous_oid,
      :published_oid,
      :state,
      :wal_seq,
      :result,
      :error_code
    ])
    |> validate_required([
      :repository_id,
      :owner_user_id,
      :workspace_ref,
      :idempotency_key,
      :argument_digest,
      :message,
      :branch,
      :state
    ])
    |> validate_inclusion(:state, @states)
    |> validate_length(:message, min: 1, max: 2_000)
    |> validate_length(:idempotency_key, is: 64)
    |> validate_length(:argument_digest, is: 64)
    |> unique_constraint(:idempotency_key)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:owner_user_id)
    |> check_constraint(:state, name: :repository_publications_state_check)
  end
end
