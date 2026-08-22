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
