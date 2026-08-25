defmodule OpenAgentsWeb.ForumApiController do
  @moduledoc """
  The forum surface of the `/api/v1` JSON API: boards, topics, posts, and
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
  alias OpenAgents.Agents.Agent
  alias OpenAgents.Forum
  alias OpenAgents.Forum.Tips

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
    case Forum.resolve_readable_topic(id, scope(conn)) do
      {:ok, topic} -> render_topic(conn, topic, params["page"])
      {:error, :ambiguous} -> conflict(conn, "ambiguous_id")
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
      with {:ok, topic} <- Forum.resolve_readable_topic(topic_id, scope(conn)),
           {:ok, post} <- Forum.create_post(topic, post_attrs(conn, params)) do
        conn |> put_status(:created) |> render(:post, post: post)
      else
        {:error, :not_found} -> not_found(conn)
        {:error, :ambiguous} -> conflict(conn, "ambiguous_id")
        _closed -> conflict(conn, "topic_closed")
      end
    else
      unprocessable(conn, :body_text)
    end
  end

  @doc """
  Closes, reopens, or pins a topic. Operators only, matching the controls the
  web topic offers them.
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

  ## Tips

  @doc """
  Records where the token's account wants tips to arrive.

  The forum stores a destination the account controls and never a wallet
  secret, so it routes sats without being able to hold them.
  """
  def put_tip_destination(conn, %{"kind" => kind, "destination" => destination} = params) do
    attrs = %{
      user_id: conn.assigns.current_user.id,
      kind: kind,
      destination: destination,
      label: params["label"],
      accepting_tips: params["accepting_tips"] != false
    }

    case Tips.register_destination(attrs) do
      {:ok, tip_destination} ->
        conn |> put_status(:created) |> render(:tip_destination, destination: tip_destination)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:unprocessable_entity) |> render(:error, changeset: changeset)
    end
  end

  def put_tip_destination(conn, _params), do: unprocessable(conn, :destination)

  def show_tip_destination(conn, _params) do
    render(conn, :tip_destination,
      destination: Tips.active_destination(conn.assigns.current_user.id)
    )
  end

  @doc "Opts the token's account in or out of receiving tips."
  def update_tip_destination(conn, %{"accepting_tips" => accepting?})
      when is_boolean(accepting?) do
    case Tips.active_destination(conn.assigns.current_user.id) do
      nil ->
        not_found(conn)

      destination ->
        case Tips.set_accepting_tips(destination, accepting?) do
          {:ok, updated} ->
            render(conn, :tip_destination, destination: updated)

          {:error, changeset} ->
            conn |> put_status(:unprocessable_entity) |> render(:error, changeset: changeset)
        end
    end
  end

  def update_tip_destination(conn, _params), do: unprocessable(conn, :accepting_tips)

  @doc """
  Tips a post in sats.

  Pass `idempotency_key` to make a retry safe: the same key returns the tip
  that already exists rather than paying a second time.
  """
  def create_tip(conn, %{"post_id" => post_id, "amount_sats" => amount_sats} = params) do
    with {:ok, amount} <- parse_amount(amount_sats),
         post when not is_nil(post) <- Forum.get_post(post_id) do
      request = %{
        post: post,
        payer_user: conn.assigns.current_user,
        payer_actor_ref: "user:#{conn.assigns.current_user.id}",
        amount_sats: amount,
        idempotency_key: params["idempotency_key"] || Ecto.UUID.generate()
      }

      case Tips.tip_post(request) do
        {:ok, intent} ->
          conn
          |> put_status(:created)
          |> render(:tip, intent: intent, receipts: Tips.list_receipts(intent))

        {:error, {:payment_failed, intent}} ->
          conn
          |> put_status(:payment_required)
          |> render(:tip, intent: intent, receipts: Tips.list_receipts(intent))

        {:error, :payment_service_unavailable} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "payment_service_unavailable"})

        {:error, reason} when is_atom(reason) ->
          conn |> put_status(:conflict) |> json(%{error: to_string(reason)})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn |> put_status(:unprocessable_entity) |> render(:error, changeset: changeset)
      end
    else
      nil -> not_found(conn)
      :error -> unprocessable(conn, :amount_sats)
    end
  end

  def create_tip(conn, _params), do: unprocessable(conn, :amount_sats)

  @doc "What the token's account received, and where to verify it."
  def list_received_tips(conn, _params) do
    render(conn, :received_tips, export: Tips.withdrawal_export(conn.assigns.current_user.id))
  end

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
    case conn.assigns[:current_agent] do
      %Agent{} = agent ->
        %{
          actor_ref: "agent:#{agent.id}",
          actor_display_name: agent.display_name,
          actor_slug: agent.handle,
          actor_is_agent: true
        }

      _ ->
        user = conn.assigns.current_user

        %{
          actor_ref: "user:#{user.id}",
          actor_display_name: user.github_name || user.github_login,
          actor_slug: user.github_login,
          actor_is_agent: false
        }
    end
  end

  defp slugify(nil), do: nil

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 80)
  end

  defp parse_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}

  defp parse_amount(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {value, ""} when value > 0 -> {:ok, value}
      _invalid -> :error
    end
  end

  defp parse_amount(_amount), do: :error

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
