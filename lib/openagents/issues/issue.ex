defmodule OpenAgents.Issues.Issue do
  use Ecto.Schema
  import Ecto.Changeset

  schema "issues" do
    field :number, :integer
    field :title, :string
    field :body, :string
    field :state, :string, default: "open"
    field :state_reason, :string
    field :locked, :boolean, default: false
    field :locked_reason, :string
    field :closed_at, :utc_datetime
    field :comments, :integer, default: 0
    field :labels, {:array, :map}, default: []
    field :assignees, {:array, :map}, default: []
    field :milestone, :map
    field :user, :map
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [
      :number,
      :title,
      :body,
      :state,
      :state_reason,
      :locked,
      :locked_reason,
      :closed_at,
      :comments,
      :labels,
      :assignees,
      :milestone,
      :user
    ])
    |> validate_required([:title, :number])
  end
end
