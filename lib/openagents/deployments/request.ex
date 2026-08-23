defmodule OpenAgents.Deployments.Request do
  @moduledoc """
  One durable intent to deploy exact bytes to one environment.

  A request records what was asked for and who asked: the exact commit, the
  exact artifact digest, the source ref and workflow the intent came from, the
  principal kind, and the idempotency key the caller spent. It never records a
  decision — admission lives on the run — so a replayed key can be answered from
  the request alone.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @principal_types ~w(user workflow operator)
  @commit_pattern ~r/\A[0-9a-f]{40}\z/
  @artifact_pattern ~r/\A[a-z0-9]+:[0-9a-f]{32,89}\z/
  @ref_pattern ~r/\A(?:refs\/(?:heads|tags)\/)[\x21-\x7e]{1,240}\z/

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "deployment_requests" do
    field :commit_sha, :string
    field :artifact_digest, :string
    field :artifact_created_at, :utc_datetime_usec
    field :source_ref, :string
    field :source_workflow, :string
    field :principal_type, :string
    field :requested_by_grant_id, :binary_id
    field :idempotency_key, :string
    field :request_digest, :string
    field :input_digest, :string
    field :requested_at, :utc_datetime_usec

    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :environment, OpenAgents.Deployments.Environment
    belongs_to :requested_by_user, OpenAgents.Accounts.User
    has_one :run, OpenAgents.Deployments.Run, foreign_key: :deployment_request_id

    timestamps()
  end

  @doc false
  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :commit_sha,
      :artifact_digest,
      :artifact_created_at,
      :source_ref,
      :source_workflow,
      :idempotency_key
    ])
    |> validate_required([
      :commit_sha,
      :artifact_digest,
      :source_ref,
      :idempotency_key,
      :principal_type,
      :request_digest,
      :input_digest,
      :requested_at
    ])
    |> update_change(:commit_sha, &String.downcase/1)
    |> validate_format(:commit_sha, @commit_pattern)
    |> validate_format(:artifact_digest, @artifact_pattern)
    |> validate_format(:source_ref, @ref_pattern)
    |> validate_length(:source_workflow, min: 1, max: 120)
    |> validate_length(:idempotency_key, min: 8, max: 255)
    |> validate_inclusion(:principal_type, @principal_types)
    |> unique_constraint(:idempotency_key,
      name: :deployment_requests_idempotency_index
    )
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:environment_id)
  end

  @doc "The principal kinds that can hold a deployment intent."
  @spec principal_types() :: [String.t()]
  def principal_types, do: @principal_types
end
