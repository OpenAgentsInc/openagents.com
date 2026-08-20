defmodule OpenAgents.Repositories.IdempotencyRequest do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "repository_idempotency_requests" do
    field :operation, :string
    field :idempotency_key, :string
    field :request_digest, :string

    belongs_to :user, OpenAgents.Accounts.User
    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :repository_import, OpenAgents.Repositories.RepositoryImport
    timestamps()
  end

  def changeset(request, user_id, operation, idempotency_key, request_digest, result) do
    request
    |> change()
    |> put_change(:user_id, user_id)
    |> put_change(:operation, operation)
    |> put_change(:idempotency_key, idempotency_key)
    |> put_change(:request_digest, request_digest)
    |> put_change(:repository_id, result.repository_id)
    |> put_change(:repository_import_id, Map.get(result, :repository_import_id))
    |> validate_required([
      :user_id,
      :operation,
      :idempotency_key,
      :request_digest,
      :repository_id
    ])
    |> validate_length(:operation, min: 1, max: 40)
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> validate_format(:request_digest, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint([:user_id, :operation, :idempotency_key])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:repository_import_id)
    |> check_constraint(:request_digest, name: :repository_idempotency_digest_check)
  end
end
