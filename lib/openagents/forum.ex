defmodule OpenAgents.Forum do
  @moduledoc """
  The forum: boards of topics and posts, ported from the live Effect forum.

  Posts keep the identity they were written under (`actor_ref` plus display
  metadata). A legacy actor whose identity is linked through
  `OpenAgents.Forum.ActorLink` resolves to a real account; unclaimed actors
  stay attributed to their legacy name.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias OpenAgents.Forum.{ActorLink, Forum, Post, Tips, Topic}
  alias OpenAgents.Repo

  @ranking_half_life_seconds 7 * 24 * 3600

  @topics_per_page 25
  @posts_per_page 50
  @recent_posts_limit 6
  @maximum_page 10_000

  # A board nobody has claimed as private is readable by anyone. An unlisted
  # board stays out of the board list but answers to its slug. A private board
  # answers to operators only, because the forum has no per-board membership.
  @public_visibilities ["public", "unlisted"]

  def topics_per_page, do: @topics_per_page
  def posts_per_page, do: @posts_per_page

  ## Forums

  def list_forums do
    Repo.all(from f in Forum, order_by: [asc: f.title])
  end

  def list_public_forums do
    Repo.all(from f in listed_forums([]), order_by: [desc: f.topic_count])
  end

  def get_forum!(id), do: Repo.get!(Forum, id)

  def get_forum_by_slug(slug), do: Repo.get_by(Forum, slug: slug)

  @doc """
  The board behind `slug`, when the caller may read it.

  Pass `operator?: true` to include private boards. Every other caller gets
  `{:error, :not_found}` for a private board, so a read surface cannot confirm
  that the board exists.
  """
  def fetch_readable_forum_by_slug(slug, opts \\ []) when is_list(opts) do
    with true <- is_binary(slug),
         %Forum{} = forum <- Repo.one(from f in readable_forums(opts), where: f.slug == ^slug) do
      {:ok, forum}
    else
      _unreadable -> {:error, :not_found}
    end
  end

  @doc """
  The boards a caller may list: every board for an operator, the public and
  listed ones for anyone else.
  """
  def list_readable_forums(opts \\ []) when is_list(opts) do
    if operator?(opts), do: list_forums(), else: list_public_forums()
  end

  defp readable_forums(opts) do
    visibilities =
      if operator?(opts), do: @public_visibilities ++ ["private"], else: @public_visibilities

    from f in Forum, where: f.visibility in ^visibilities
  end

  # The boards a listing may name. `readable_forums/1` says who may read a
  # board; discoverability says whether a board belongs in a list at all. An
  # unlisted board answers to its slug and stays out of every listing --
  # including a digest of what was posted on it -- whoever is looking, so a
  # board opened as a smoke test cannot arrive on a surface that lists boards.
  defp listed_forums(opts) do
    from f in readable_forums(opts),
      where: f.discoverability == "listed" and f.visibility != "unlisted"
  end

  defp operator?(opts), do: Keyword.get(opts, :operator?, false)

  ## Topics

  @doc """
  One page of topics in a board.

  Pass `order: :ranked` to weigh settled tips alongside recency. Ranking reads
  stored settlement totals only, so it returns the same order whether or not a
  payment service is reachable.
  """
  def list_topics(%Forum{id: forum_id}, opts \\ []) when is_list(opts) do
    page = parse_page(opts[:page])

    from(t in Topic,
      where: t.forum_id == ^forum_id and is_nil(t.archived_at),
      limit: ^@topics_per_page,
      offset: ^((page - 1) * @topics_per_page)
    )
    |> order_topics(opts[:order])
    |> Repo.all()
  end

  defp order_topics(query, :ranked) do
    order_by(
      query,
      ^[
        desc: dynamic([t], t.pin_state),
        desc: ranking_score(),
        desc: dynamic([t], t.updated_at),
        desc: dynamic([t], t.id)
      ]
    )
  end

  defp order_topics(query, _order) do
    order_by(query, [t], desc: t.pin_state, desc: t.updated_at, desc: t.id)
  end

  # Recency plus a bounded, decaying tip term. `ln` keeps a large tip from
  # dominating a board, and the exponential decay means sats buy attention for
  # about a week rather than forever.
  defp ranking_score do
    dynamic(
      [t],
      fragment(
        "ln(1 + ?::float) * exp(- EXTRACT(EPOCH FROM (now() - ?)) / ?)",
        t.tip_sats_counted,
        t.updated_at,
        ^@ranking_half_life_seconds
      )
    )
  end

  @doc "How long a settled tip keeps most of its ranking weight, in seconds."
  def ranking_half_life_seconds, do: @ranking_half_life_seconds

  def count_topics(%Forum{id: forum_id}) do
    Repo.one!(
      from t in Topic,
        select: count(),
        where: t.forum_id == ^forum_id and is_nil(t.archived_at)
    )
  end

  def get_topic!(id), do: Repo.get!(Topic, id)

  @doc """
  The topic behind `id`, when the caller may read the board that holds it.

  An archived topic, a malformed identifier, and a topic on a board the caller
  cannot read all answer `{:error, :not_found}`.
  """
  def fetch_readable_topic(id, opts \\ []) when is_list(opts) do
    with {:ok, uuid} <- cast_uuid(id),
         %Topic{} = topic <-
           Repo.one(
             from t in Topic,
               join: f in subquery(readable_forums(opts)),
               on: f.id == t.forum_id,
               where: t.id == ^uuid and is_nil(t.archived_at)
           ) do
      {:ok, topic}
    else
      _unreadable -> {:error, :not_found}
    end
  end

  @doc """
  One page of topics whose title or visible post bodies match `term`, newest
  activity first.

  Pass `:forum` to search one board, `:operator?` to include private boards,
  and `:page` to page through the matches. Each topic arrives with its board
  preloaded, because a search crosses boards.
  """
  def search_topics(term, opts \\ []) when is_binary(term) and is_list(opts) do
    page = parse_page(opts[:page])

    term
    |> search_query(opts)
    |> order_by([topic: t], desc: t.updated_at, desc: t.id)
    |> limit(^@topics_per_page)
    |> offset(^((page - 1) * @topics_per_page))
    |> preload(:forum)
    |> Repo.all()
  end

  @doc "How many topics `term` matches."
  def count_search_topics(term, opts \\ []) when is_binary(term) and is_list(opts) do
    term
    |> search_query(opts)
    |> select([topic: t], count(t.id))
    |> Repo.one!()
  end

  defp search_query(term, opts) do
    pattern = "%" <> escape_like(String.trim(term)) <> "%"

    query =
      from t in Topic,
        as: :topic,
        join: f in subquery(readable_forums(opts)),
        on: f.id == t.forum_id,
        where: is_nil(t.archived_at),
        where:
          ilike(t.title, ^pattern) or
            exists(
              from p in Post,
                where:
                  p.topic_id == parent_as(:topic).id and p.state == "visible" and
                    ilike(p.body_text, ^pattern),
                select: 1
            )

    case opts[:forum] do
      %Forum{id: forum_id} -> from [topic: t] in query, where: t.forum_id == ^forum_id
      _every_board -> query
    end
  end

  # `%`, `_`, and `\\` are LIKE metacharacters: a search for "100%" is a search
  # for that text, not for every title.
  defp escape_like(term), do: String.replace(term, ~r/([\\%_])/, "\\\\\\1")

  defp cast_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast_uuid(_id), do: {:error, :not_found}

  def get_topic_by_ref(forum_id, slug_or_id) when is_binary(slug_or_id) do
    if String.match?(
         slug_or_id,
         ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
       ) do
      Repo.get_by(Topic, forum_id: forum_id, id: slug_or_id)
    else
      Repo.get_by(Topic, forum_id: forum_id, slug: slug_or_id)
    end
  end

  @doc "One page of visible posts in a topic, oldest first."
  def list_posts(%Topic{id: topic_id}, opts \\ []) when is_list(opts) do
    page = parse_page(opts[:page])

    from(p in Post,
      where: p.topic_id == ^topic_id and p.state == "visible",
      order_by: [asc: p.post_number],
      limit: ^@posts_per_page,
      offset: ^((page - 1) * @posts_per_page)
    )
    |> Repo.all()
  end

  def count_posts(%Topic{id: topic_id}) do
    Repo.one!(
      from p in Post,
        select: count(),
        where: p.topic_id == ^topic_id and p.state == "visible"
    )
  end

  @doc """
  The newest visible post in each of the most recently active topics on the
  boards a caller may list, newest post first.

  One row per topic, so a single busy thread cannot crowd out every other
  board in a caller's digest of the forum. The scope is the one
  `list_readable_forums/1` answers for the same caller, so a surface that
  shows recent posts beside a link to the board list cannot disagree with it.

  Each post arrives with its topic and board preloaded, and carries the
  identity it was written under rather than one resolved for it, so a caller
  renders the same author a thread renders. A migrated post keeps its legacy
  display name; an identity claim binds the reference to an account, it does
  not rewrite the byline.

  Pass `:limit` to cap the rows; the cap is bounded by the posts-per-page size
  so the read stays a bounded page rather than a scan of every post.
  """
  def list_recent_posts(opts \\ []) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, @recent_posts_limit) |> bound_limit()

    topics =
      from t in Topic,
        join: f in subquery(listed_forums(opts)),
        on: f.id == t.forum_id,
        where: is_nil(t.archived_at),
        order_by: [desc: t.updated_at, desc: t.id],
        limit: ^limit

    # The topics come first and bounded, so the posts read only touches the
    # rows of the handful of topics that can appear.
    latest =
      from p in Post,
        join: t in subquery(topics),
        on: t.id == p.topic_id,
        where: p.state == "visible",
        distinct: [asc: p.topic_id],
        order_by: [desc: p.post_number]

    from(p in subquery(latest), order_by: [desc: p.created_at, desc: p.id])
    |> Repo.all()
    |> Repo.preload(topic: :forum)
  end

  defp bound_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@posts_per_page)
  defp bound_limit(_limit), do: @recent_posts_limit

  @doc "One post by id, or `nil` when the id is unknown or malformed."
  def get_post(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Post, uuid)
      :error -> nil
    end
  end

  @doc "The next post number in a topic."
  def next_post_number(topic_id) do
    Repo.one!(
      from p in Post,
        select: coalesce(max(p.post_number), 0),
        where: p.topic_id == ^topic_id
    ) + 1
  end

  @doc """
  Creates a topic with its first post. `attrs` needs topic fields plus
  `:body_text` for the first post. Both rows share one transaction.
  """
  def create_topic(%Forum{} = forum, attrs) do
    {body_text, topic_attrs} = Map.pop(attrs, :body_text)
    idempotency_key = Map.get(attrs, :idempotency_key) || Ecto.UUID.generate()

    changeset =
      %Topic{forum_id: forum.id}
      |> Topic.changeset(Map.put(topic_attrs, :idempotency_key, idempotency_key))

    Multi.new()
    |> Multi.insert(:topic, changeset)
    |> Multi.run(:first_post, fn _repo, %{topic: topic} ->
      create_post(topic, Map.put(topic_attrs, :body_text, body_text), idempotency_key)
    end)
    |> Multi.update(:topic_counts, fn %{topic: topic, first_post: post} ->
      Ecto.Changeset.change(topic)
      |> Ecto.Changeset.put_change(:first_post_id, post.id)
      |> Ecto.Changeset.put_change(:latest_post_id, post.id)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{topic: %{id: topic_id}}} -> {:ok, Repo.get!(Topic, topic_id)}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Adds a post to a topic under the poster's identity. Bumps the topic's
  `updated_at` (the board's sort key), advances the counters on both topic
  and forum, and refuses closed or locked surfaces.
  """
  def create_post(%Topic{} = topic, attrs, idempotency_key \\ nil) do
    with :ok <- ensure_open(topic),
         {:ok, post} <- insert_post(topic, attrs, idempotency_key) do
      bump_topic(topic, post)
      bump_forum(topic.forum_id)
      {:ok, post}
    end
  end

  defp ensure_open(%Topic{id: id}) do
    if Repo.get!(Topic, id).state == "open", do: :ok, else: {:error, :topic_closed}
  end

  defp insert_post(topic, attrs, idempotency_key) do
    %Post{
      topic_id: topic.id,
      post_number: next_post_number(topic.id),
      idempotency_key: idempotency_key || Ecto.UUID.generate()
    }
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  defp bump_topic(topic, post) do
    now = utc_now()

    {_count, _} =
      from(t in Topic, where: t.id == ^topic.id)
      |> Repo.update_all(
        set: [latest_post_id: post.id, post_count: post.post_number, updated_at: now]
      )
  end

  defp bump_forum(forum_id) do
    from(f in Forum, where: f.id == ^forum_id)
    |> Repo.update_all(inc: [post_count: 1])
  end

  @doc "The post behind `id`, or `{:error, :not_found}`."
  def fetch_post(id) do
    with {:ok, uuid} <- cast_uuid(id),
         %Post{} = post <- Repo.get(Post, uuid) do
      {:ok, post}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc "Soft-deletes a post by marking it deleted. Records an audit event."
  def delete_post(%Post{} = post, moderator \\ nil) do
    result =
      post
      |> Ecto.Changeset.change(state: "deleted", archived_at: utc_now())
      |> Repo.update()

    case result do
      {:ok, _} ->
        Tips.withdraw_post_weight(post)
        audit_moderation("forum.post.deleted", moderator, post)

      _ ->
        :ok
    end

    result
  end

  def hide_post(%Post{} = post, moderator \\ nil) do
    result =
      post
      |> Ecto.Changeset.change(state: "hidden")
      |> Repo.update()

    case result do
      {:ok, _} ->
        Tips.withdraw_post_weight(post)
        audit_moderation("forum.post.hidden", moderator, post)

      _ ->
        :ok
    end

    result
  end

  defp audit_moderation(event_type, moderator, %Post{id: id}) do
    OpenAgents.Audit.record!(event_type, actor_for_audit(moderator), "forum_post", id)
  end

  defp actor_for_audit(nil), do: {:system, "forum"}

  defp actor_for_audit(%{id: id}), do: {:user, id}

  @doc "Closes or reopens a topic."
  def set_topic_state(%Topic{} = topic, state) when state in ["open", "closed"] do
    topic
    |> Ecto.Changeset.change(state: state)
    |> Repo.update()
  end

  def pin_topic(%Topic{} = topic, pinned?) do
    topic
    |> Ecto.Changeset.change(pin_state: if(pinned?, do: "pinned", else: "normal"))
    |> Repo.update()
  end

  @doc """
  The account that owns `actor_ref`, or `nil` when nobody has claimed it.
  Only links with status `linked` resolve.
  """
  def actor_user(nil), do: nil

  def actor_user(actor_ref) do
    Repo.one(
      from l in ActorLink,
        join: u in OpenAgents.Accounts.User,
        on: u.id == l.user_id,
        where: l.actor_ref == ^actor_ref and l.status == "linked",
        select: u,
        limit: 1
    )
  end

  ## Identity linking

  @doc "Starts a claim: a pending link binding an account to a legacy identity."
  def start_actor_link(user, actor_ref, proof_method \\ "legacy_credential") do
    %ActorLink{}
    |> ActorLink.changeset(%{
      user_id: user.id,
      actor_ref: actor_ref,
      status: "pending",
      proof_method: proof_method,
      proof_evidence: %{"started_at" => DateTime.to_iso8601(utc_now())}
    })
    |> Repo.insert()
  end

  @doc "Approves a pending link after its proof has been checked."
  def approve_actor_link(%ActorLink{status: "pending"} = link) do
    link
    |> ActorLink.changeset(%{
      status: "linked",
      linked_at: utc_now(),
      proof_evidence:
        Map.put(link.proof_evidence || %{}, "approved_at", DateTime.to_iso8601(utc_now()))
    })
    |> Repo.update()
  end

  def reject_actor_link(%ActorLink{status: "pending"} = link) do
    link
    |> ActorLink.changeset(%{status: "rejected", rejected_at: utc_now()})
    |> Repo.update()
  end

  def list_actor_links(%OpenAgents.Accounts.User{} = user) do
    Repo.all(from l in ActorLink, where: l.user_id == ^user.id, order_by: [desc: l.inserted_at])
  end

  @doc "Every claim still waiting on an operator, oldest first."
  def list_pending_actor_links do
    Repo.all(from l in ActorLink, where: l.status == "pending", order_by: [asc: l.inserted_at])
  end

  @doc "The claim behind `id`, or `{:error, :not_found}`."
  def fetch_actor_link(id) do
    with {:ok, uuid} <- cast_uuid(id),
         %ActorLink{} = link <- Repo.get(ActorLink, uuid) do
      {:ok, link}
    else
      _missing -> {:error, :not_found}
    end
  end

  ## Shared helpers

  def parse_page(page) when is_integer(page), do: page |> max(1) |> min(@maximum_page)

  def parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {number, ""} -> parse_page(number)
      :error -> 1
      {_number, _trailing} -> 1
    end
  end

  def parse_page(_page), do: 1

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
