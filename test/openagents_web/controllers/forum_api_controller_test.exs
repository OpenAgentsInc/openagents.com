defmodule OpenAgentsWeb.ForumApiControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Forum
  alias OpenAgents.Repo

  setup %{conn: conn} do
    {:ok, forum} =
      %Forum.Forum{}
      |> Forum.Forum.changeset(%{slug: "general", title: "General"})
      |> Repo.insert()

    {:ok, conn: conn, forum: forum}
  end

  defp topic(forum, attrs \\ %{}) do
    {:ok, topic} =
      Forum.create_topic(
        forum,
        Map.merge(
          %{
            title: "Hello world",
            slug: "hello-world",
            body_text: "First post body",
            idempotency_key: Ecto.UUID.generate(),
            actor_ref: "agent:user_ed8297d8-1279-4b43-a1e7-f7867da19e20",
            actor_display_name: "Orrery",
            actor_slug: "orrery"
          },
          attrs
        )
      )

    topic
  end

  test "GET /api/v3/forum lists public boards", %{conn: conn} do
    conn = get(conn, ~p"/api/v3/forum")

    assert %{"boards" => [board]} = json_response(conn, 200)
    assert board["slug"] == "general"
    assert board["title"] == "General"
  end

  test "GET /api/v3/forum/topics lists a board's topics", %{conn: conn, forum: forum} do
    topic(forum)

    conn = get(conn, ~p"/api/v3/forum/topics?forum=general")

    assert %{"topics" => [t], "pagination" => pagination} = json_response(conn, 200)
    assert t["title"] == "Hello world"
    assert t["url"] =~ "/forum/t/"
    assert pagination["total"] == 1
  end

  test "GET /api/v3/forum/topics/:id returns the thread with posts", %{conn: conn, forum: forum} do
    topic = topic(forum)

    conn = get(conn, ~p"/api/v3/forum/topics/#{topic.id}")

    assert %{"topic" => t, "posts" => posts} = json_response(conn, 200)
    assert t["title"] == "Hello world"
    assert [%{"body_text" => "First post body"}] = posts
  end

  test "POST /api/v3/forum/topics creates a topic attributed to the token account", %{conn: conn} do
    conn =
      conn
      |> put_forge_api_token("forum-api-create")
      |> post(~p"/api/v3/forum/topics", %{
        forum: "general",
        title: "From the CLI",
        body_text: "Posted over the API"
      })

    assert response = json_response(conn, 201)
    assert response["topic"]["title"] == "From the CLI"
    assert hd(response["posts"])["author"]["is_agent"] == false
  end

  test "POST /api/v3/forum/topics requires authentication", %{conn: conn} do
    conn = post(conn, ~p"/api/v3/forum/topics", %{forum: "general", title: "x", body_text: "y"})

    assert json_response(conn, 401)
  end

  test "POST /api/v3/forum/topics/:id/posts replies to a topic", %{conn: conn, forum: forum} do
    topic = topic(forum)

    conn =
      conn
      |> put_forge_api_token("forum-api-reply")
      |> post(~p"/api/v3/forum/topics/#{topic.id}/posts", %{body_text: "API reply"})

    assert %{"post" => post} = json_response(conn, 201)
    assert post["post_number"] == 2
    assert Forum.count_posts(topic) == 2
  end

  test "POST /api/v3/forum/claims starts an identity claim", %{conn: conn} do
    conn =
      conn
      |> put_forge_api_token("forum-api-claim")
      |> post(~p"/api/v3/forum/claims", %{
        actor_ref: "agent:user_ed8297d8-1279-4b43-a1e7-f7867da19e20"
      })

    assert %{"claim" => %{"status" => "pending"}} = json_response(conn, 201)
  end

  test "GET /api/v3/forum/claims lists the caller's claims", %{conn: conn} do
    authed = put_forge_api_token(conn, "forum-api-list-claims")

    {:ok, _} =
      Forum.start_actor_link(github_user("api-token-forum-api-list-claims"), "agent:user_1")

    _ = authed

    conn = get(authed, ~p"/api/v3/forum/claims")

    assert %{"claims" => claims} = json_response(conn, 200)
    assert length(claims) >= 1
  end

  test "unknown board is 404", %{conn: conn} do
    conn = get(conn, ~p"/api/v3/forum/topics?forum=nope")

    assert json_response(conn, 404)
  end
end
