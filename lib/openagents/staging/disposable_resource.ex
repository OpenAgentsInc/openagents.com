defmodule OpenAgents.Staging.DisposableResource do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  @kinds ~w(account machine recording repository)

  schema "staging_disposable_resources" do
    field :run_id, :string
    field :kind, :string
    field :resource_id, Ecto.UUID

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          run_id: String.t(),
          kind: String.t(),
          resource_id: Ecto.UUID.t(),
          inserted_at: DateTime.t()
        }

  def create_changeset(resource, attributes) do
    resource
    |> cast(attributes, [:run_id, :kind, :resource_id])
    |> validate_required([:run_id, :kind, :resource_id])
    |> validate_format(:run_id, ~r/\A[a-z0-9][a-z0-9-]{7,63}\z/)
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:kind, :resource_id])
    |> check_constraint(:run_id, name: :staging_disposable_run_id_check)
    |> check_constraint(:kind, name: :staging_disposable_kind_check)
  end
end
