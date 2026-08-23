defmodule OpenAgentsWeb.ForumApiController do
  @moduledoc """
  The forum surface of the `/api/v3` JSON API: boards, topics, posts, and
  legacy identity claims.

  Reads are public. Writes require a `forge:write` API token and attribute
  posts to the token's account. Moderation and claim review require an
  operator account behind that token.

  Every read resolves through `OpenAgents.Forum`'s readable scopes, so a
  private board, an archived topic, and a hidden or deleted post never reach
  an unauthorized caller.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Accounts
  alias OpenAgents.Forum

  def boards(conn, _params) do
    render(conn, :boards, forums: Forum.list_readable_forums(scope(conn)))
  end

  def topics(conn, params) do
    case {params["q"], params["forum"]} do
      {query, _slug} when is_binary(query) -> search(conn, query, params)
      {_query, slug} when is_binary(slug) -> board_topics(conn, slug, params)
      _missing_board -> not_found(conn)
    end
  end

  def show_topic(conn, %{"id" => id} = params) do
    case Forum.fetch_readable_topic(id, scope(conn)) do
      {:ok, topic} -> render_topic(conn, topic, params["page"])
      {:error, :not_found} -> not_found(conn)
    end
  end

  def create_topic(conn, %{"forum" => slug, "title" => title, "body_text" => body_text} = params) do
    cond do
      not valid_text?(title) ->
        unprocessable(conn, :title)

      not valid_text?(body_text) ->
        unprocessable(conn, :body_text)

      true ->
        with {:ok, forum} <- Forum.fetch_readable_forum_by_slug(slug, scope(conn)),
             {:ok, topic} <- Forum.create_topic(forum, topic_attrs(conn, params)) do
          conn
          |> put_status(:created)
          |> render(:topic,
            topic: topic,
            posts: [first_post(topic)],
            pagination: %{page: 1, per_page: Forum.posts_per_page(), total: 1}
          )
        else
          {:error, :not_found} ->
            not_found(conn)

          {:error, %Ecto.Changeset{} = changeset} ->
            conn |> put_status(:unprocessable_entity) |> render(:error, changeset: changeset)

          _closed ->
            conflict(conn, "topic_closed")
        end
    end
  end

  def create_post(conn, %{"topic_id" => topic_id, "body_text" => body_text} = params) do
    if valid_text?(body_text) do
      with {:ok, topic} <- Forum.fetch_readable_topic(topic_id, scope(conn)),
           {:ok, post} <- Forum.create_post(topic, post_attrs(conn, params)) do
        conn |> put_status(:created) |> render(:post, post: post)
      else
        {:error, :not_found} -> not_found(conn)
        _closed -> conflict(conn, "topic_closed")
      end
    else
      unprocessable(conn, :body_text)
    end
  end

  @doc """
  Closes, reopens, or pins a topic. Operators only, matching the controls the
  web thread offers them.
  """
  def update_topic(conn, %{"id" => id} = params) do
    with :ok <- ensure_operator(conn),
         {:ok, topic} <- Forum.fetch_readable_topic(id, scope(conn)),
         {:ok, topic} <- apply_topic_state(topic, params),
         {:ok, topic} <- apply_topic_pin(topic, params) do
      render_topic(conn, topic, nil)
    else
      {:error, :forbidden} -> forbidden(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_state} -> unprocessable(conn, :state, ~s(must be "open" or "closed"))
      {:error, :invalid_pinned} -> unprocessable(conn, :pinned, "must be a boolean")
      {:error, %Ecto.Changeset{} = changeset} -> render_changeset_error(conn, changeset)
    end
  end

  @doc """
  Hides or deletes a post. Operators only. Both states are soft: the post row
  stays, and the read surfaces stop returning it.
  """
  def update_post(conn, %{"id" => id, "state" => state}) do
    with :ok <- ensure_operator(conn),
         {:ok, post} <- Forum.fetch_post(id),
         {:ok, post} <- moderate_post(post, state, conn.assigns.current_user) do
      render(conn, :post, post: post)
    else
      {:error, :forbidden} -> forbidden(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_state} -> unprocessable(conn, :state, post_state_message())
      {:error, %Ecto.Changeset{} = changeset} -> render_changeset_error(conn, changeset)
    end
  end

  def update_post(conn, _params), do: unprocessable(conn, :state, post_state_message())

  def create_claim(conn, %{"actor_ref" => actor_ref}) when is_binary(actor_ref) do
    case Forum.start_actor_link(conn.assigns.current_user, String.trim(actor_ref), "api_token") do
      {:ok, link} ->
        conn |> put_status(:created) |> render(:claim, claim: link)

      {:error, changeset} ->
        render_changeset_error(conn, changeset)
    end
  end

  def create_claim(conn, _params), do: unprocessable(conn, :actor_ref)

  def list_claims(conn, _params) do
    render(conn, :claims, claims: Forum.list_actor_links(conn.assigns.current_user))
  end

  @doc "Every claim waiting on review. Operators only."
  def pending_claims(conn, _params) do
    case ensure_operator(conn) do
      :ok -> render(conn, :claims, claims: Forum.list_pending_actor_links())
      {:error, :forbidden} -> forbidden(conn)
    end
  end

  @doc "Approves or rejects a pending claim. Operators only."
  def update_claim(conn, %{"id" => id, "status" => status}) do
    with :ok <- ensure_operator(conn),
         {:ok, link} <- Forum.fetch_actor_link(id),
         {:ok, link} <- review_claim(link, status) do
      render(conn, :claim, claim: link)
    else
      {:error, :forbidden} -> forbidden(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_status} -> unprocessable(conn, :status, claim_status_message())
      {:error, :not_pending} -> conflict(conn, "claim_not_pending")
      {:error, %Ecto.Changeset{} = changeset} -> render_changeset_error(conn, changeset)
    end
  end

  def update_claim(conn, _params), do: unprocessable(conn, :status, claim_status_message())

  ## Reads

  defp board_topics(conn, slug, params) do
    case Forum.fetch_readable_forum_by_slug(slug, scope(conn)) do
      {:ok, forum} ->
        page = Forum.parse_page(params["page"])

        render(conn, :topics,
          topics: Forum.list_topics(forum, page: page),
          forum: forum,
          query: nil,
          pagination: pagination(page, Forum.topics_per_page(), Forum.count_topics(forum))
        )

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  defp search(conn, query, params) do
    scope = scope(conn)

    case search_board(params["forum"], scope) do
      {:ok, forum} ->
        page = Forum.parse_page(params["page"])
        opts = scope |> Keyword.put(:forum, forum) |> Keyword.put(:page, page)

        render(conn, :topics,
          topics: Forum.search_topics(query, opts),
          forum: forum,
          query: query,
          pagination:
            pagination(
              page,
              Forum.topics_per_page(),
              Forum.count_search_topics(query, Keyword.delete(opts, :page))
            )
        )

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  # A search without `forum` crosses every readable board.
  defp search_board(slug, scope) when is_binary(slug),
    do: Forum.fetch_readable_forum_by_slug(slug, scope)

  defp search_board(_slug, _scope), do: {:ok, nil}

  defp render_topic(conn, topic, page_param) do
    page = Forum.parse_page(page_param)

    render(conn, :topic,
      topic: topic,
      posts: Forum.list_posts(topic, page: page),
      pagination: pagination(page, Forum.posts_per_page(), Forum.count_posts(topic))
    )
  end

  ## Writes

  defp apply_topic_state(topic, %{"state" => state}) when state in ["open", "closed"],
    do: Forum.set_topic_state(topic, state)

  defp apply_topic_state(_topic, %{"state" => _other}), do: {:error, :invalid_state}

  defp apply_topic_state(topic, _params), do: {:ok, topic}

  defp apply_topic_pin(topic, %{"pinned" => pinned}) when is_boolean(pinned),
    do: Forum.pin_topic(topic, pinned)

  defp apply_topic_pin(_topic, %{"pinned" => _other}), do: {:error, :invalid_pinned}

  defp apply_topic_pin(topic, _params), do: {:ok, topic}

  defp moderate_post(post, "hidden", moderator), do: Forum.hide_post(post, moderator)

  defp moderate_post(post, "deleted", moderator), do: Forum.delete_post(post, moderator)

  defp moderate_post(_post, _state, _moderator), do: {:error, :invalid_state}

  defp review_claim(%{status: "pending"} = link, "linked"), do: Forum.approve_actor_link(link)

  defp review_claim(%{status: "pending"} = link, "rejected"), do: Forum.reject_actor_link(link)

  defp review_claim(%{status: "pending"}, _status), do: {:error, :invalid_status}

  defp review_claim(_link, status) when status in ["linked", "rejected"],
    do: {:error, :not_pending}

  defp review_claim(_link, _status), do: {:error, :invalid_status}

  ## Helpers

  defp first_post(topic) do
    case Forum.list_posts(topic) do
      [post | _rest] -> post
      [] -> nil
    end
  end

  defp scope(conn), do: [operator?: Accounts.admin?(conn.assigns[:current_user])]

  defp ensure_operator(conn) do
    if Accounts.admin?(conn.assigns[:current_user]), do: :ok, else: {:error, :forbidden}
  end

  defp pagination(page, per_page, total),
    do: %{page: page, per_page: per_page, total: total}

  defp topic_attrs(conn, params) do
    actor_attrs(conn)
    |> Map.merge(%{
      title: params["title"],
      slug: slugify(params["title"]),
      body_text: params["body_text"],
      idempotency_key: Map.get(params, "idempotency_key") || Ecto.UUID.generate()
    })
  end

  defp post_attrs(conn, params) do
    actor_attrs(conn)
    |> Map.merge(%{
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
  defp valid_text?(_value), do: false

  defp render_changeset_error(conn, changeset),
    do: conn |> put_status(:unprocessable_entity) |> render(:error, changeset: changeset)

  defp post_state_message, do: ~s(must be "hidden" or "deleted")

  defp claim_status_message, do: ~s(must be "linked" or "rejected")

  defp unprocessable(conn, field, message \\ "must be a non-empty string"),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: %{field => [message]}})

  defp conflict(conn, error), do: conn |> put_status(:conflict) |> json(%{error: error})

  defp forbidden(conn), do: conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})
end
