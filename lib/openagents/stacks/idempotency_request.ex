defmodule OpenAgents.Stacks.IdempotencyRequest do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "pull_request_stack_idempotency_requests" do
    field :operation, :string
    field :idempotency_key, :string
    field :request_digest, :string

    belongs_to :user, OpenAgents.Accounts.User
    belongs_to :stack, OpenAgents.Stacks.Stack
    timestamps()
  end

  def changeset(request, user_id, operation, idempotency_key, request_digest, stack_id) do
    request
    |> change()
    |> put_change(:user_id, user_id)
    |> put_change(:operation, operation)
    |> put_change(:idempotency_key, idempotency_key)
    |> put_change(:request_digest, request_digest)
    |> put_change(:stack_id, stack_id)
    |> validate_required([:user_id, :operation, :idempotency_key, :request_digest, :stack_id])
    |> validate_length(:operation, min: 1, max: 40)
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> validate_format(:request_digest, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint([:user_id, :operation, :idempotency_key])
    |> check_constraint(:request_digest, name: :pull_request_stack_idempotency_digest_check)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:stack_id)
  end
end
