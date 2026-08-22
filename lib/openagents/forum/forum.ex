defmodule OpenAgents.Forum.Forum do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "forum_forums" do
    field :slug, :string
    field :title, :string
    field :description, :string
    field :visibility, :string, default: "public"
    field :discoverability, :string, default: "listed"
    field :locked, :boolean, default: false
    field :topic_count, :integer, default: 0
    field :post_count, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(forum, attrs) do
    forum
    |> cast(attrs, [:slug, :title, :description, :visibility, :discoverability, :locked])
    |> validate_required([:slug, :title])
    |> unique_constraint([:slug])
    |> validate_inclusion(:visibility, ["public", "unlisted", "private"])
  end
end
