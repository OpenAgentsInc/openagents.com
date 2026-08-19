defmodule OpenAgents.Issues.Comment do
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Issues.Issue

  schema "comments" do
    field :body, :string
    field :user, :map
    field :created_at, :utc_datetime
    field :updated_at, :utc_datetime

    belongs_to :issue, Issue
  end

  @doc false
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body, :user, :issue_id, :created_at, :updated_at])
    |> validate_required([:body, :issue_id, :created_at, :updated_at])
  end
end
