defmodule OpenAgentsWeb.ForumLiveUpdatesTest do
  @moduledoc """
  The forum's own surfaces as live surfaces (#158, following #154).

  `#154` gave the forum a publisher and wired the homepage to it. The forum
  itself still read once and never again, which was most visible on a topic:
  a discussion that never shows a reply arriving reads as a bug rather than as
  a delay.

  What matters here is not only that a page changes. It is that it changes
  through the viewer's own authorized read. The announcement carries a topic
  id and nothing else, so a refresh cannot hand a viewer a board they could
  not have opened, and it cannot put a board kept off listings onto one. Both
  directions are proved: a write on a board the viewer cannot read moves
  nothing, and a viewer whose board stops being readable loses the page they
  already had.

  The counts stay stored counters. A board list that counted topics to print
  its badges would load every board's collection to measure it, once per
  board, on the one page that lists them all.
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
    reader = github_user("forum-live-reader")

    %{conn: Plug.Test.init_test_session(conn, %{"user_id" => reader.id}), reader: reader}
  end

  describe "a topic" do
    test "a reply written elsewhere joins the topic", context do
      board = board!("general", "General")
      topic = topic!(board, "What a promise costs", "what-a-promise-costs")

      {:ok, view, _html} = live(context.conn, ~p"/forum/t/#{topic.id}")

      refute render(view) =~ "Rather less than that"

      {:ok, reply} =
        Forum.create_post(topic, Map.merge(@legacy_actor, %{body_text: "Rather less than that"}))

      assert has_element?(view, "#posts-#{reply.id}", "Rather less than that")

      # The identity the post was written under, not one resolved for it: a
      # migrated post keeps its legacy byline until a claim binds it, and a
      # refresh must not attribute it differently from a mount.
      assert has_element?(view, "#posts-#{reply.id}", "Orrery")
    end

    test "a post hidden elsewhere leaves the topic", context do
      board = board!("general", "General")
      topic = topic!(board, "Said in haste", "said-in-haste")

      {:ok, hasty} =
        Forum.create_post(topic, Map.merge(@legacy_actor, %{body_text: "Said in haste"}))

      {:ok, view, _html} = live(context.conn, ~p"/forum/t/#{topic.id}")

      assert has_element?(view, "#posts-#{hasty.id}")

      {:ok, _hidden} = Forum.hide_post(hasty, nil)

      refute has_element?(view, "#posts-#{hasty.id}")
    end

    test "a topic closed elsewhere retires the composer", context do
      board = board!("general", "General")
      topic = topic!(board, "Settled", "settled")

      {:ok, view, _html} = live(context.conn, ~p"/forum/t/#{topic.id}")

      assert has_element?(view, "#reply-form")

      {:ok, _closed} = Forum.set_topic_state(topic, "closed")

      refute has_element?(view, "#reply-form")
    end

    test "a post on another topic costs the page nothing", context do
      board = board!("general", "General")
      topic = topic!(board, "The one you are reading", "the-one-you-are-reading")
      elsewhere = topic!(board, "Somewhere else entirely", "somewhere-else-entirely")

      {:ok, view, _html} = live(context.conn, ~p"/forum/t/#{topic.id}")

      sql =
        capture_queries(view.pid, fn ->
          Forum.broadcast_posts(elsewhere.id)
          render(view)
        end)

      # Every post on the forum announces itself on one topic, so a page
      # reading one topic tells by id alone that this is not its own. A busy
      # board costs it no read at all.
      refute Enum.any?(sql, &String.contains?(&1, ~s(FROM "forum_posts")))
      refute render(view) =~ "Somewhere else entirely"
    end
  end

  describe "a board" do
    test "a topic started elsewhere joins the board", context do
      board = board!("general", "General")

      {:ok, view, _html} = live(context.conn, ~p"/forum/f/general")

      assert has_element?(view, "#topics-empty")

      topic = topic!(board, "Started in another tab", "started-in-another-tab")

      assert has_element?(view, ~s{a[href="/forum/t/#{topic.id}"]}, "Started in another tab")
    end

    test "a reply elsewhere moves the topic's reply count", context do
      board = board!("general", "General")
      topic = topic!(board, "Counting", "counting")

      {:ok, view, _html} = live(context.conn, ~p"/forum/f/general")

      assert has_element?(view, "#topics-#{topic.id}", "1 posts")

      {:ok, _reply} = Forum.create_post(topic, Map.merge(@legacy_actor, %{body_text: "Two"}))

      assert has_element?(view, "#topics-#{topic.id}", "2 posts")
    end

    test "a board kept off listings still follows its own page", context do
      # An unlisted board answers to its slug. Staying off the board list is
      # not the same as being unreadable, and the page that resolved it should
      # update like any other.
      void = board!("void", "Void", discoverability: "unlisted")

      {:ok, view, _html} = live(context.conn, ~p"/forum/f/void")

      topic = topic!(void, "Smoke test", "smoke-test")

      assert has_element?(view, ~s{a[href="/forum/t/#{topic.id}"]}, "Smoke test")
    end
  end

  describe "the board list" do
    test "a topic started elsewhere moves the board's count", context do
      board = board!("general", "General")

      {:ok, view, _html} = live(context.conn, ~p"/forum")

      assert has_element?(view, "#board-topics-general", "0 topics")

      _topic = topic!(board, "The first of them", "the-first-of-them")

      assert has_element?(view, "#board-topics-general", "1 topics")
    end

    test "the badge is a stored counter, not a collection loaded to measure it",
         context do
      board = board!("general", "General")
      for index <- 1..3, do: topic!(board, "Topic #{index}", "topic-#{index}")

      {:ok, view, _html} = live(context.conn, ~p"/forum")

      sql =
        capture_queries(view.pid, fn ->
          Forum.broadcast_posts(Ecto.UUID.generate())
          render(view)
        end)

      assert Enum.any?(sql, &String.contains?(&1, ~s(FROM "forum_forums")))
      refute Enum.any?(sql, &String.contains?(&1, ~s(FROM "forum_topics")))
    end
  end

  describe "authorization" do
    test "a topic on a private board never reaches the board list", context do
      private = board!("operators", "Operators", visibility: "private")

      {:ok, view, _html} = live(context.conn, ~p"/forum")

      _topic = topic!(private, "Not for you", "not-for-you")

      # The announcement reached the page -- the list re-read -- and the
      # page's own scope refused the board, which is what makes this an
      # authorization result rather than an undelivered broadcast.
      refute render(view) =~ "Operators"
      refute render(view) =~ "Not for you"
    end

    test "a topic on a board kept off listings never reaches the board list", context do
      void = board!("void", "Void", discoverability: "unlisted")

      {:ok, view, _html} = live(context.conn, ~p"/forum")

      _topic = topic!(void, "Smoke test", "smoke-test")

      refute render(view) =~ "Void"
      refute render(view) =~ "Smoke test"
    end

    test "a board that stops being readable takes its topic with it", context do
      board = board!("general", "General")
      topic = topic!(board, "Readable when you opened it", "readable-when-you-opened-it")

      {:ok, view, _html} = live(context.conn, ~p"/forum/t/#{topic.id}")

      assert render(view) =~ "Readable when you opened it"

      board
      |> Ecto.Changeset.change(visibility: "private")
      |> Repo.update!()

      Forum.broadcast_posts(topic.id)

      assert_redirect(view, ~p"/forum")
    end

    test "a board that stops being readable closes its own page", context do
      board = board!("general", "General")
      topic = topic!(board, "Still here", "still-here")

      {:ok, view, _html} = live(context.conn, ~p"/forum/f/general")

      board
      |> Ecto.Changeset.change(visibility: "private")
      |> Repo.update!()

      Forum.broadcast_posts(topic.id)

      assert_redirect(view, ~p"/forum")
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

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

  # Telemetry fires in the process that ran the query, so filtering on the
  # LiveView's pid isolates the refresh from the write that provoked it.
  defp capture_queries(pid, fun) do
    handler = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach(
      handler,
      Repo.config()[:telemetry_prefix] ++ [:query],
      fn _event, _measurements, metadata, _config ->
        if self() == pid, do: send(test, {handler, metadata.query})
      end,
      nil
    )

    try do
      fun.()
      drain(handler, [])
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(handler, acc) do
    receive do
      {^handler, query} -> drain(handler, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
