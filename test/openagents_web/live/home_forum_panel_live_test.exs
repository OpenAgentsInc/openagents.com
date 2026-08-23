defmodule OpenAgentsWeb.HomeForumPanelLiveTest do
  @moduledoc """
  The `Recent posts` panel on the signed-in homepage (#137).

  The panel inherits the dashboard contract `#128` set: it reads through the
  forum's own viewer-authorized read, caps its rows, links to `/forum` rather
  than to one board, and says what is empty instead of rendering nothing.

  What matters here is that it cannot say more than `/forum` says. A board the
  viewer cannot read stays out. A board kept off listings stays out, whoever is
  looking, because a board opened as a smoke test must not arrive on the
  homepage. And a migrated post reads under the identity its thread shows it
  under, so the dashboard cannot attribute a post to an account the forum
  would not.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Forum
  alias OpenAgents.Repo

  @legacy_actor %{
    actor_ref: "agent:user_ed8297d8-1279-4b43-a1e7-f7867da19e20",
    actor_display_name: "Orrery",
    actor_slug: "orrery"
  }

  setup %{conn: conn} do
    %{conn: sign_in(conn, "home-forum-reader")}
  end

  test "the panel lists the newest post of each recently active topic", %{conn: conn} do
    board = board!("product-promises", "Product promises")
    quiet = topic!(board, "What a promise costs", "what-a-promise-costs")
    busy = topic!(board, "Where the receipts live", "where-the-receipts-live")
    {:ok, newest} = Forum.create_post(busy, Map.merge(@legacy_actor, %{body_text: "Still here"}))

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#dashboard-post-list")
    assert has_element?(view, "#dashboard-post-#{newest.id}")
    assert has_element?(view, ~s{a[href="/forum/t/#{busy.id}"]}, "Where the receipts live")
    assert has_element?(view, ~s{a[href="/forum/t/#{quiet.id}"]}, "What a promise costs")

    # The board is named beside the author, because a cross-board digest is
    # unreadable without the board.
    assert has_element?(view, "#dashboard-post-#{newest.id} .post-rail__meta", "Product promises")

    # One row per topic: the busy thread's earlier posts are not rows of their
    # own, so a single thread cannot fill the panel.
    assert rows(view) == 2
  end

  test "the panel points at the forum, not at one board", %{conn: conn} do
    board = board!("product-promises", "Product promises")
    topic!(board, "What a promise costs", "what-a-promise-costs")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ~s{a[href="/forum"]}, "View all")
    refute has_element?(view, ~s{a[href="/forum/f/product-promises"]})
  end

  test "the panel caps its rows", %{conn: conn} do
    board = board!("product-promises", "Product promises")

    for index <- 1..9 do
      topic!(board, "Topic #{index}", "topic-#{index}")
    end

    {:ok, view, _html} = live(conn, ~p"/")

    assert rows(view) == 6
  end

  test "a post on a board the viewer cannot read never appears", %{conn: conn} do
    private = board!("operators", "Operators", visibility: "private")
    topic = topic!(private, "Rotating the signing key", "rotating-the-signing-key")

    {:ok, view, html} = live(conn, ~p"/")

    refute html =~ "Rotating the signing key"
    refute has_element?(view, ~s{a[href="/forum/t/#{topic.id}"]})

    # The same post reaches the operator whose board it is, which is what makes
    # the refusal above an authorization result rather than an empty database.
    {:ok, operator, _html} = live(log_in_admin_user(build_conn(), "home-forum-operator"), ~p"/")
    assert has_element?(operator, ~s{a[href="/forum/t/#{topic.id}"]})
  end

  test "a board kept off listings never appears, operator or not", %{conn: conn} do
    void = board!("void", "Void", discoverability: "unlisted")
    topic = topic!(void, "Smoke test", "smoke-test")

    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, ~s{a[href="/forum/t/#{topic.id}"]})

    {:ok, operator, _html} = live(log_in_admin_user(build_conn(), "home-forum-operator"), ~p"/")
    refute has_element?(operator, ~s{a[href="/forum/t/#{topic.id}"]})

    # The board still answers to its slug. Keeping it off the homepage is a
    # listing rule, not a permission.
    assert {:ok, _forum} = Forum.fetch_readable_forum_by_slug("void")
  end

  test "a migrated post reads under the identity its thread shows", %{conn: conn} do
    board = board!("product-promises", "Product promises")
    topic = topic!(board, "What a promise costs", "what-a-promise-costs")
    [post] = Forum.list_posts(topic)

    # An account that has not claimed the legacy identity, and one that has.
    # Neither may take the post's byline unless the thread gives it to them.
    stranger = github_user("home-forum-stranger", "orrery-lookalike")
    {:ok, link} = Forum.start_actor_link(stranger, @legacy_actor.actor_ref)
    {:ok, _linked} = Forum.approve_actor_link(link)

    {:ok, home, html} = live(conn, ~p"/")
    {:ok, thread, _html} = live(conn, ~p"/forum/t/#{topic.id}")

    byline = text_at(thread, "#posts-#{post.id} span.font-semibold")
    meta = text_at(home, "#dashboard-post-#{post.id} .post-rail__meta")

    assert byline == "Orrery"
    assert String.starts_with?(meta, byline)
    refute html =~ "orrery-lookalike"
  end

  test "with nothing readable the panel names its scope", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#dashboard-post-list")
    assert has_element?(view, ".panel__empty", "No posts yet on the boards you can read.")
  end

  defp sign_in(conn, key) do
    Plug.Test.init_test_session(conn, %{"user_id" => github_user(key).id})
  end

  defp board!(slug, title, opts \\ []) do
    {:ok, board} =
      %Forum.Forum{}
      |> Forum.Forum.changeset(%{
        slug: slug,
        title: title,
        visibility: Keyword.get(opts, :visibility, "public"),
        discoverability: Keyword.get(opts, :discoverability, "listed")
      })
      |> Repo.insert()

    board
  end

  defp topic!(board, title, slug) do
    {:ok, topic} =
      Forum.create_topic(
        board,
        Map.merge(@legacy_actor, %{
          title: title,
          slug: slug,
          body_text: "Body of #{title}",
          idempotency_key: Ecto.UUID.generate()
        })
      )

    topic
  end

  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".post-rail__row")
    |> Enum.count()
  end

  defp text_at(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end
end
