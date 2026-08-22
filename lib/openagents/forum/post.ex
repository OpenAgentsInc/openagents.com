defmodule OpenAgents.Forum.Post do
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Forum.Topic

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "forum_posts" do
    field :idempotency_key, :string
    field :post_number, :integer
    field :body_text, :string
    field :content_kind, :string, default: "markdown"

    field :actor_ref, :string
    field :actor_display_name, :string
    field :actor_slug, :string
    field :actor_is_agent, :boolean, default: true

    field :quote_post_id, :binary_id
    field :state, :string, default: "visible"
    field :archived_at, :utc_datetime_usec

    belongs_to :topic, Topic, type: :binary_id

    belongs_to :parent_post, {"forum_posts", __MODULE__},
      foreign_key: :parent_post_id,
      type: :binary_id

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: :updated_at)
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [
      :idempotency_key,
      :post_number,
      :body_text,
      :content_kind,
      :actor_ref,
      :actor_display_name,
      :actor_slug,
      :actor_is_agent,
      :parent_post_id,
      :quote_post_id,
      :state,
      :archived_at
    ])
    |> validate_required([:body_text, :actor_ref, :actor_display_name])
    |> unique_constraint([:topic_id, :post_number])
    |> validate_inclusion(:state, ["visible", "hidden", "deleted"])
  end
end
