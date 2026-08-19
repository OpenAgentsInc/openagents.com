defmodule OpenAgents.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    field :number, :integer
    field :title, :string
    field :owner, :string
    field :state, :string, default: "open"

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:number, :title, :owner, :state])
    |> validate_required([:number, :title, :owner, :state])
  end
end
