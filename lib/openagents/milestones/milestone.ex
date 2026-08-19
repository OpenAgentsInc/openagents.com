defmodule OpenAgents.Milestones.Milestone do
  use Ecto.Schema
  import Ecto.Changeset

  schema "milestones" do
    field :title, :string
    field :state, :string, default: "open"
    field :description, :string
    field :due_on, :string
    field :number, :integer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(milestone, attrs) do
    milestone
    |> cast(attrs, [:title, :state, :description, :due_on, :number])
    |> validate_required([:title, :number])
  end
end
