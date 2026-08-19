defmodule OpenAgents.ProjectFields.ProjectField do
  use Ecto.Schema
  import Ecto.Changeset

  schema "project_fields" do
    field :name, :string
    field :data_type, :string
    field :options, :map
    field :project_id, :id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(project_field, attrs) do
    project_field
    |> cast(attrs, [:name, :data_type, :options, :project_id])
    |> validate_required([:name, :data_type, :project_id])
  end
end
