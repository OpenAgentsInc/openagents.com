defmodule OpenAgents.Repositories.Membership do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "repository_memberships" do
    belongs_to :repository, OpenAgents.Repositories.Repository, primary_key: true
    belongs_to :user, OpenAgents.Accounts.User, primary_key: true
    field :role, :string

    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:repository_id, :user_id, :role])
    |> validate_required([:repository_id, :user_id, :role])
    |> validate_inclusion(:role, ~w(owner maintainer contributor viewer))
    |> unique_constraint([:repository_id, :user_id])
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:role, name: :repository_memberships_role_check)
  end
end
