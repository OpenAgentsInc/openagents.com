defmodule OpenAgents.Repositories.MachineGrant do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "repository_machine_grants" do
    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :machine, OpenAgents.Machines.Machine
    belongs_to :created_by_user, OpenAgents.Accounts.User
    field :operations, {:array, :string}, default: []

    timestamps()
  end

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:repository_id, :machine_id, :created_by_user_id, :operations])
    |> validate_required([:repository_id, :machine_id, :created_by_user_id, :operations])
    |> validate_length(:operations, min: 1, max: 2)
    |> validate_subset(:operations, ~w(read write))
    |> unique_constraint([:repository_id, :machine_id])
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:machine_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> check_constraint(:operations, name: :repository_machine_grants_operations_present)
    |> check_constraint(:operations, name: :repository_machine_grants_operations_allowed)
  end
end
