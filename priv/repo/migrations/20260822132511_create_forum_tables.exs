defmodule OpenAgents.Repo.Migrations.CreateForumTables do
  use Ecto.Migration

  def change do
    create table(:forum_forums, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :slug, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :visibility, :string, null: false, default: "public"
      add :discoverability, :string, null: false, default: "listed"
      add :locked, :boolean, null: false, default: false
      add :topic_count, :bigint, null: false, default: 0
      add :post_count, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:forum_forums, [:slug])

    create constraint(:forum_forums, :forum_forums_visibility_check,
             check: "visibility IN ('public', 'unlisted', 'private')"
           )

    create table(:forum_topics, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :forum_id, references(:forum_forums, type: :uuid, on_delete: :restrict), null: false

      add :idempotency_key, :string, null: false
      add :slug, :string, null: false
      add :title, :string, null: false

      # Legacy actor identity. Posts keep the identity they were written
      # under; a linked account is resolved through forum_actor_links.
      add :actor_ref, :string, null: false
      add :actor_display_name, :string, null: false
      add :actor_slug, :string
      add :actor_is_agent, :boolean, null: false, default: true

      add :state, :string, null: false, default: "open"
      add :pin_state, :string, null: false, default: "normal"
      add :post_count, :bigint, null: false, default: 1
      add :first_post_id, :uuid
      add :latest_post_id, :uuid
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:forum_topics, [:idempotency_key])
    create unique_index(:forum_topics, [:forum_id, :slug])

    create index(:forum_topics, [:forum_id, :pin_state, :created_at],
             where: "archived_at IS NULL"
           )

    create index(:forum_topics, [:actor_ref])

    create constraint(:forum_topics, :forum_topics_state_check,
             check: "state IN ('open', 'closed')"
           )

    create constraint(:forum_topics, :forum_topics_pin_state_check,
             check: "pin_state IN ('normal', 'pinned')"
           )

    create table(:forum_posts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :topic_id, references(:forum_topics, type: :uuid, on_delete: :restrict), null: false

      add :idempotency_key, :string, null: false
      add :post_number, :bigint, null: false
      add :body_text, :text, null: false
      add :content_kind, :string, null: false, default: "markdown"

      add :actor_ref, :string, null: false
      add :actor_display_name, :string, null: false
      add :actor_slug, :string
      add :actor_is_agent, :boolean, null: false, default: true

      add :parent_post_id,
          references(:forum_posts, type: :uuid, on_delete: :nilify_all)

      add :quote_post_id, :uuid

      add :state, :string, null: false, default: "visible"
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:forum_posts, [:idempotency_key])
    create unique_index(:forum_posts, [:topic_id, :post_number])

    create index(:forum_posts, [:topic_id, :post_number],
             where: "archived_at IS NULL",
             name: :forum_posts_topic_number_visible_index
           )

    create index(:forum_posts, [:actor_ref])

    create constraint(:forum_posts, :forum_posts_state_check,
             check: "state IN ('visible', 'hidden', 'deleted')"
           )

    execute("SELECT 1", "SELECT 1")
  end
end
