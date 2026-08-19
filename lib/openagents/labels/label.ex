defmodule OpenAgents.Labels.Label do
  use Ecto.Schema
  import Ecto.Changeset

  schema "labels" do
    field :name, :string
    field :color, :string
    field :description, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(label, attrs) do
    label
    |> cast(attrs, [:name, :color, :description])
    |> validate_required([:name, :color, :description])
  end
end
