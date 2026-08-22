defmodule OpenAgentsWeb.ForumApiController do
  @moduledoc """
  The forum surface of the `/api/v3` JSON API: boards, topics, posts, and
  legacy identity claims.

  Reads are public. Writes require a `forge:write` API token and attribute
  posts to the token's account.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Forum

  # Errors arrive as {:error, :not_found}, {:error, :missing_forum}, or
  # {:error, field, message}; each `with/else` maps them onto a response.

  def boards(conn, _params) do
    render(conn, :boards, forums: Forum.list_public_forums())
  end

  def topics(conn, params) do
    case fetch_forum(params) do
      {:ok, forum} ->
        {topics, total} = forum_topics_page(forum, params)

        render(conn, :topics,
          topics: topics,
          forum: forum,
          pagination: %{
            page: Forum.parse_page(params["page"]),
            per_page: Forum.topics_per_page(),
            total: total
          }
        )

      _missing ->
        not_found(conn)
    end
  end

  def show_topic(conn, %{"id" => id} = params) do
    topic = Forum.get_topic!(id)
    posts = Forum.list_posts(topic, page: params["page"])

    render(conn, :topic,
      topic: topic,
      posts: posts,
      pagination: %{
        page: Forum.parse_page(params["page"]),
        per_page: Forum.posts_per_page(),
        total: Forum.count_posts(topic)
      }
    )
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def create_topic(conn, %{"forum" => slug, "title" => title, "body_text" => body_text} = params) do
    cond do
      not valid_text?(title) ->
        unprocessable(conn, :title)

      not valid_text?(body_text) ->
        unprocessable(conn, :body_text)

      true ->
        case fetch_forum(%{"forum" => slug}) do
          {:ok, forum} ->
            case Forum.create_topic(forum, topic_attrs(conn, params)) do
              {:ok, topic} ->
                conn
                |> put_status(:created)
                |> render(:topic,
                  topic: topic,
                  posts: [first_post(topic)],
                  pagination: %{
                    page: 1,
                    per_page: Forum.posts_per_page(),
                    total: 1
                  }
                )

              {:error, %Ecto.Changeset{} = changeset} ->
                conn |> put_status(:unprocessable_entity) |> render(:error, changeset: changeset)

              _other ->
                conn |> put_status(:conflict) |> json(%{error: "topic_closed"})
            end

          _missing ->
            not_found(conn)
        end
    end
  end

  def create_post(conn, %{"topic_id" => topic_id, "body_text" => body_text} = params) do
    if valid_text?(body_text) do
      topic = Forum.get_topic!(topic_id)

      attrs =
        actor_attrs(conn)
        |> Map.merge(%{
          body_text: body_text,
          idempotency_key: Map.get(params, "idempotency_key") || Ecto.UUID.generate()
        })

      case Forum.create_post(topic, attrs) do
        {:ok, post} ->
          conn |> put_status(:created) |> render(:post, post: post)

        _closed ->
          conn |> put_status(:conflict) |> json(%{error: "topic_closed"})
      end
    else
      unprocessable(conn, :body_text)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def create_claim(conn, %{"actor_ref" => actor_ref}) when is_binary(actor_ref) do
    case Forum.start_actor_link(conn.assigns.current_user, String.trim(actor_ref), "api_token") do
      {:ok, link} ->
        conn |> put_status(:created) |> render(:claim, claim: link)

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> render(:error, changeset: changeset)
    end
  end

  def list_claims(conn, _params) do
    render(conn, :claims, claims: Forum.list_actor_links(conn.assigns.current_user))
  end

  ## Helpers

  defp first_post(topic) do
    case Forum.list_posts(topic) do
      [post | _] -> post
      [] -> nil
    end
  end

  defp forum_topics_page(forum, params) do
    page = Forum.parse_page(params["page"])
    topics = Forum.list_topics(forum, page: page)
    total = Forum.count_topics(forum)
    {topics, total}
  end

  defp fetch_forum(%{"forum" => slug}) when is_binary(slug) do
    case Forum.get_forum_by_slug(slug) do
      nil -> {:error, :not_found}
      forum -> {:ok, forum}
    end
  end

  defp fetch_forum(_params), do: {:error, :missing_forum}

  defp topic_attrs(conn, params) do
    actor_attrs(conn)
    |> Map.merge(%{
      title: params["title"],
      slug: slugify(params["title"]),
      body_text: params["body_text"],
      idempotency_key: Map.get(params, "idempotency_key") || Ecto.UUID.generate()
    })
  end

  defp actor_attrs(conn) do
    user = conn.assigns.current_user

    %{
      actor_ref: "user:#{user.id}",
      actor_display_name: user.github_name || user.github_login,
      actor_slug: user.github_login,
      actor_is_agent: false
    }
  end

  defp slugify(nil), do: nil

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 80)
  end

  defp valid_text?(value) when is_binary(value) and byte_size(value) > 0, do: true
  defp valid_text?(_), do: false

  defp unprocessable(conn, field),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: %{field => ["must be a non-empty string"]}})

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})
end
