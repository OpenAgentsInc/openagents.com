defmodule OpenAgents.Labels.Label do
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Repositories.Repository

  schema "labels" do
    field :name, :string
    field :color, :string
    field :description, :string
    belongs_to :repository, Repository, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(label, attrs) do
    label
    |> cast(attrs, [:name, :color, :description, :repository_id])
    |> validate_required([:name, :color, :repository_id])
    |> unique_constraint([:repository_id, :name])
    |> foreign_key_constraint(:repository_id)
  end
end
