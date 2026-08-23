defmodule OpenAgents.ForumTest do
  use OpenAgents.DataCase, async: true

  alias OpenAgents.Forum

  defp user do
    {:ok, user} =
      %OpenAgents.Accounts.User{}
      |> Ecto.Changeset.change(%{
        github_id: System.unique_integer([:positive]),
        github_login: "forum-test-#{System.unique_integer()}",
        github_name: "Forum Test",
        github_avatar_url: "https://example.com/a.png"
      })
      |> Repo.insert()

    user
  end

  defp forum do
    {:ok, forum} =
      %OpenAgents.Forum.Forum{}
      |> OpenAgents.Forum.Forum.changeset(%{slug: "general", title: "General"})
      |> Repo.insert()

    forum
  end

  defp actor do
    %{
      actor_ref: "agent:user_ed8297d8-1279-4b43-a1e7-f7867da19e20",
      actor_display_name: "Orrery",
      actor_slug: "orrery"
    }
  end

  describe "create_topic/2" do
    test "creates a topic and its first post in one transaction" do
      forum = forum()

      {:ok, topic} =
        Forum.create_topic(
          forum,
          Map.merge(actor(), %{title: "Hello", slug: "hello", body_text: "First post"})
        )

      assert topic.title == "Hello"
      assert topic.post_count == 1
      [post] = Forum.list_posts(topic)
      assert post.body_text == "First post"
      assert post.post_number == 1
      assert topic.first_post_id == post.id
    end
  end

  describe "create_post/3" do
    test "appends posts with incrementing numbers and bumps the topic" do
      forum = forum()

      {:ok, topic} =
        Forum.create_topic(forum, Map.merge(actor(), %{title: "T", slug: "t", body_text: "a"}))

      {:ok, second} = Forum.create_post(topic, Map.merge(actor(), %{body_text: "b"}))
      assert second.post_number == 2

      bumped = Forum.get_topic!(topic.id)
      assert bumped.latest_post_id == second.id
    end

    test "refuses posts to closed topics" do
      forum = forum()

      {:ok, topic} =
        Forum.create_topic(forum, Map.merge(actor(), %{title: "T", slug: "t", body_text: "a"}))

      {:ok, _} = Forum.set_topic_state(topic, "closed")

      assert {:error, :topic_closed} =
               Forum.create_post(topic, Map.merge(actor(), %{body_text: "b"}))
    end
  end

  describe "list_recent_posts/1" do
    test "returns one row per topic, newest post first, with topic and board loaded" do
      board = forum()

      {:ok, quiet} =
        Forum.create_topic(
          board,
          Map.merge(actor(), %{title: "Quiet", slug: "quiet", body_text: "a"})
        )

      {:ok, busy} =
        Forum.create_topic(
          board,
          Map.merge(actor(), %{title: "Busy", slug: "busy", body_text: "b"})
        )

      {:ok, _} = Forum.create_post(busy, Map.merge(actor(), %{body_text: "b2"}))
      {:ok, newest} = Forum.create_post(busy, Map.merge(actor(), %{body_text: "b3"}))

      assert [first, second] = Forum.list_recent_posts()

      # The busy thread contributes its newest post and nothing else, so one
      # active topic cannot fill a caller's digest of the forum.
      assert first.id == newest.id
      assert first.topic.id == busy.id
      assert first.topic.forum.slug == "general"
      assert second.topic.id == quiet.id
    end

    test "leaves out a board that is kept off listings" do
      {:ok, hidden} =
        %OpenAgents.Forum.Forum{}
        |> OpenAgents.Forum.Forum.changeset(%{
          slug: "void",
          title: "Void",
          discoverability: "unlisted"
        })
        |> Repo.insert()

      {:ok, _topic} =
        Forum.create_topic(
          hidden,
          Map.merge(actor(), %{title: "Smoke test", slug: "smoke-test", body_text: "ping"})
        )

      assert Forum.list_recent_posts() == []

      # An operator reads the board by its slug, and still does not meet it in
      # a listing.
      assert Forum.list_recent_posts(operator?: true) == []
      assert {:ok, _} = Forum.fetch_readable_forum_by_slug("void")
    end

    test "leaves out a private board unless the caller is an operator" do
      {:ok, private} =
        %OpenAgents.Forum.Forum{}
        |> OpenAgents.Forum.Forum.changeset(%{
          slug: "operators",
          title: "Operators",
          visibility: "private"
        })
        |> Repo.insert()

      {:ok, _topic} =
        Forum.create_topic(
          private,
          Map.merge(actor(), %{title: "Internal", slug: "internal", body_text: "only us"})
        )

      assert Forum.list_recent_posts() == []
      assert [post] = Forum.list_recent_posts(operator?: true)
      assert post.topic.forum.slug == "operators"
    end

    test "leaves out a hidden post and caps the rows" do
      board = forum()

      {:ok, topic} =
        Forum.create_topic(board, Map.merge(actor(), %{title: "T", slug: "t", body_text: "one"}))

      {:ok, second} = Forum.create_post(topic, Map.merge(actor(), %{body_text: "two"}))
      {:ok, _} = Forum.hide_post(second)

      assert [post] = Forum.list_recent_posts(limit: 1)
      assert post.body_text == "one"
    end
  end

  describe "identity linking" do
    test "approve links an actor to an account and resolves it" do
      user = user()
      {:ok, link} = Forum.start_actor_link(user, "agent:user_1234")

      assert link.status == "pending"

      {:ok, linked} = Forum.approve_actor_link(link)
      assert linked.status == "linked"
      assert Forum.actor_user("agent:user_1234").id == user.id
      assert Forum.actor_user("agent:user_other") == nil
    end

    test "reject leaves nothing resolvable" do
      user = user()
      {:ok, link} = Forum.start_actor_link(user, "agent:user_5678")
      {:ok, rejected} = Forum.reject_actor_link(link)
      assert rejected.status == "rejected"
      assert Forum.actor_user("agent:user_5678") == nil
    end
  end
end
