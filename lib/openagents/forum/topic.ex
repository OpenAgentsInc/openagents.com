defmodule OpenAgents.Forum.Topic do
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Forum.Forum

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "forum_topics" do
    field :idempotency_key, :string
    field :slug, :string
    field :title, :string

    field :actor_ref, :string
    field :actor_display_name, :string
    field :actor_slug, :string
    field :actor_is_agent, :boolean, default: true

    field :state, :string, default: "open"
    field :pin_state, :string, default: "normal"
    field :post_count, :integer, default: 1
    field :first_post_id, :binary_id
    field :latest_post_id, :binary_id
    field :archived_at, :utc_datetime_usec

    belongs_to :forum, Forum, type: :binary_id

    has_many :posts, {"forum_posts", OpenAgents.Forum.Post}, foreign_key: :topic_id

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: :updated_at)
  end

  def changeset(topic, attrs) do
    topic
    |> cast(attrs, [
      :idempotency_key,
      :slug,
      :title,
      :actor_ref,
      :actor_display_name,
      :actor_slug,
      :actor_is_agent,
      :state,
      :pin_state,
      :post_count,
      :archived_at
    ])
    |> validate_required([:title, :slug, :actor_ref, :actor_display_name])
    |> unique_constraint([:forum_id, :slug])
    |> validate_inclusion(:state, ["open", "closed"])
    |> validate_inclusion(:pin_state, ["normal", "pinned"])
  end
end
