defmodule OpenAgentsWeb.LegacyForumControllerTest do
  use OpenAgentsWeb.ConnCase, async: true

  alias OpenAgents.Forum
  alias OpenAgents.Repo

  describe "legacy forum redirects" do
    setup do
      {:ok, forum} =
        %Forum.Forum{}
        |> Forum.Forum.changeset(%{
          slug: "legacy-redirects",
          title: "Legacy redirects",
          description: "Board for legacy redirect tests"
        })
        |> Repo.insert()

      {:ok, topic} =
        Forum.create_topic(forum, %{
          title: "A topic with a legacy link",
          slug: "a-topic-with-a-legacy-link",
          body_text: "First post",
          idempotency_key: Ecto.UUID.generate(),
          actor_ref: "agent:user_0123abcd",
          actor_display_name: "Artanis",
          actor_slug: "artanis"
        })

      %{forum: forum, topic: topic}
    end

    test "a legacy topic id redirects to the topic it named", %{conn: conn, topic: topic} do
      conn = get(conn, "/forum/topic/#{topic.id}")

      assert redirected_to(conn) == ~p"/forum/t/#{topic.id}"
      assert conn.status == 302
    end

    test "a legacy post id redirects to the topic it belongs to", %{
      conn: conn,
      topic: topic
    } do
      {:ok, post} =
        Forum.create_post(topic, %{
          body_text: "A reply",
          actor_ref: "agent:user_0123abcd",
          actor_display_name: "Artanis"
        })

      conn = get(conn, "/forum/post/#{post.id}")

      assert redirected_to(conn) == ~p"/forum/t/#{topic.id}"
      assert conn.status == 302
    end

    test "an unknown legacy topic id returns 404", %{conn: conn} do
      conn = get(conn, "/forum/topic/#{Ecto.UUID.generate()}")
      assert response(conn, 404) == "Not found"
    end

    test "an unknown legacy post id returns 404", %{conn: conn} do
      conn = get(conn, "/forum/post/#{Ecto.UUID.generate()}")
      assert response(conn, 404) == "Not found"
    end

    test "a malformed legacy id returns 404", %{conn: conn} do
      conn = get(conn, "/forum/post/not-a-uuid")
      assert response(conn, 404) == "Not found"
    end
  end
end
