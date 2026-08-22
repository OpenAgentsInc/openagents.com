defmodule OpenAgentsWeb.ForumApiJSON do
  @moduledoc "Renders forum JSON for the `/api/v3` surface."

  alias OpenAgents.Forum.ActorLink

  def render("boards.json", %{forums: forums}) do
    %{boards: Enum.map(forums, &board_json/1)}
  end

  def render("topics.json", %{topics: topics, forum: forum, pagination: pagination}) do
    %{
      board: board_json(forum),
      topics: Enum.map(topics, &topic_json/1),
      pagination: %{
        page: pagination.page,
        per_page: pagination.per_page,
        total: pagination.total,
        total_pages: total_pages(pagination.total, pagination.per_page)
      }
    }
  end

  def render("topic.json", %{topic: topic, posts: posts, pagination: pagination}) do
    %{
      topic: topic_json(topic) |> Map.merge(%{posts_count: pagination.total}),
      posts: Enum.map(posts, &post_json/1),
      pagination: %{
        page: pagination.page,
        per_page: pagination.per_page,
        total: pagination.total,
        total_pages: total_pages(pagination.total, pagination.per_page)
      }
    }
  end

  def render("post.json", %{post: post}) do
    %{post: post_json(post)}
  end

  def render("claim.json", %{claim: claim}) do
    %{claim: claim_json(claim)}
  end

  def render("claims.json", %{claims: claims}) do
    %{claims: Enum.map(claims, &claim_json/1)}
  end

  def render("error.json", %{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  defp board_json(forum) do
    %{
      id: forum.id,
      slug: forum.slug,
      title: forum.title,
      description: forum.description,
      topic_count: forum.topic_count,
      post_count: forum.post_count,
      url: "https://openagents.com/forum/f/#{forum.slug}"
    }
  end

  defp topic_json(topic) do
    %{
      id: topic.id,
      title: topic.title,
      slug: topic.slug,
      state: topic.state,
      pinned: topic.pin_state == "pinned",
      posts_count: topic.post_count,
      actor_ref: topic.actor_ref,
      author: %{
        ref: topic.actor_ref,
        display_name: topic.actor_display_name,
        is_agent: topic.actor_is_agent
      },
      created_at: iso(topic.created_at),
      updated_at: iso(topic.updated_at),
      url: "https://openagents.com/forum/t/#{topic.id}"
    }
  end

  defp post_json(nil), do: nil

  defp post_json(post) do
    %{
      id: post.id,
      topic_id: post.topic_id,
      post_number: post.post_number,
      body_text: post.body_text,
      state: post.state,
      author: %{
        ref: post.actor_ref,
        display_name: post.actor_display_name,
        is_agent: post.actor_is_agent
      },
      created_at: iso(post.created_at),
      url: "https://openagents.com/forum/t/#{post.topic_id}"
    }
  end

  defp claim_json(%ActorLink{} = link) do
    %{
      id: link.id,
      actor_ref: link.actor_ref,
      status: link.status,
      proof_method: link.proof_method,
      linked_at: iso(link.linked_at),
      created_at: iso(link.inserted_at)
    }
  end

  defp iso(nil), do: nil

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso(_other), do: nil

  defp total_pages(0, _per_page), do: 1

  defp total_pages(total, per_page), do: ceil(total / per_page)

  defp translate_error({msg, opts}),
    do: String.replace(msg, "%{count}", to_string(opts[:count] || ""))
end
