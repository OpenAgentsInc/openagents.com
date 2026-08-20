defmodule OpenAgents.Repositories.ProvisioningOutbox do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "repository_provisioning_outbox" do
    field :operation, :string
    field :state, :string, default: "pending"
    field :attempt_count, :integer, default: 0
    field :retry_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :error_code, :string

    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :repository_import, OpenAgents.Repositories.RepositoryImport
    timestamps()
  end

  def changeset(outbox, repository_id, repository_import_id, operation) do
    outbox
    |> change()
    |> put_change(:repository_id, repository_id)
    |> put_change(:repository_import_id, repository_import_id)
    |> put_change(:operation, operation)
    |> put_change(:state, "pending")
    |> put_change(:attempt_count, 0)
    |> put_change(:retry_at, DateTime.utc_now())
    |> validate_required([:repository_id, :operation, :state, :attempt_count, :retry_at])
    |> validate_inclusion(:operation, ~w(create github_import))
    |> validate_inclusion(:state, ~w(pending running completed failed))
    |> unique_constraint(:repository_id)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:repository_import_id)
    |> check_constraint(:operation, name: :repository_provisioning_operation_check)
    |> check_constraint(:state, name: :repository_provisioning_state_check)
  end

  def transition_changeset(outbox, attrs) do
    outbox
    |> cast(attrs, [:state, :attempt_count, :retry_at, :claimed_at, :completed_at, :error_code])
    |> validate_required([:state, :attempt_count, :retry_at])
    |> validate_inclusion(:state, ~w(pending running completed failed))
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_length(:error_code, max: 80)
    |> check_constraint(:state, name: :repository_provisioning_state_check)
  end
end
