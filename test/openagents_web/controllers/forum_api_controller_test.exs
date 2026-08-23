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

  describe "search" do
    test "matches a topic title across every readable board", %{conn: conn, forum: forum} do
      topic(forum, %{title: "Router latency", slug: "router-latency"})
      topic(forum, %{title: "Something else", slug: "something-else"})

      conn = get(conn, ~p"/api/v3/forum/topics?q=latency")

      assert %{"query" => "latency", "topics" => [t], "board" => nil} = json_response(conn, 200)
      assert t["title"] == "Router latency"
      assert t["board"]["slug"] == "general"
    end

    test "matches a visible post body", %{conn: conn, forum: forum} do
      topic(forum, %{title: "Deploy notes", slug: "deploy-notes", body_text: "watch the walrus"})

      conn = get(conn, ~p"/api/v3/forum/topics?q=walrus")

      assert %{"topics" => [t]} = json_response(conn, 200)
      assert t["title"] == "Deploy notes"
    end

    test "stays inside one board when given a board", %{conn: conn, forum: forum} do
      {:ok, other} =
        %Forum.Forum{}
        |> Forum.Forum.changeset(%{slug: "meta", title: "Meta"})
        |> Repo.insert()

      topic(forum, %{title: "Shared word here", slug: "shared-general"})
      topic(other, %{title: "Shared word there", slug: "shared-meta"})

      conn = get(conn, ~p"/api/v3/forum/topics?forum=meta&q=shared")

      assert %{"topics" => [t], "board" => board} = json_response(conn, 200)
      assert board["slug"] == "meta"
      assert t["title"] == "Shared word there"
    end

    test "never returns a private board's topics to an anonymous caller", %{conn: conn} do
      private = private_forum()
      topic(private, %{title: "Private plan", slug: "private-plan"})

      conn = get(conn, ~p"/api/v3/forum/topics?q=private")

      assert %{"topics" => []} = json_response(conn, 200)
    end

    test "returns a private board's topics to an operator", %{conn: conn} do
      private = private_forum()
      topic(private, %{title: "Private plan", slug: "private-plan"})

      conn =
        conn
        |> operator_token("forum-api-search-operator")
        |> get(~p"/api/v3/forum/topics?q=private")

      assert %{"topics" => [t]} = json_response(conn, 200)
      assert t["title"] == "Private plan"
    end
  end

  describe "authorization of reads" do
    test "GET /api/v3/forum omits a private board", %{conn: conn} do
      private_forum()

      conn = get(conn, ~p"/api/v3/forum")

      assert %{"boards" => boards} = json_response(conn, 200)
      assert Enum.map(boards, & &1["slug"]) == ["general"]
    end

    test "GET /api/v3/forum lists a private board for an operator", %{conn: conn} do
      private_forum()

      conn = conn |> operator_token("forum-api-boards-operator") |> get(~p"/api/v3/forum")

      assert %{"boards" => boards} = json_response(conn, 200)
      assert "private" in Enum.map(boards, & &1["slug"])
    end

    test "a private board's topic list is 404 for an anonymous caller", %{conn: conn} do
      private_forum()

      conn = get(conn, ~p"/api/v3/forum/topics?forum=private")

      assert json_response(conn, 404)
    end

    test "a private board's thread is 404 for an anonymous caller", %{conn: conn} do
      topic = topic(private_forum(), %{title: "Private plan", slug: "private-plan"})

      conn = get(conn, ~p"/api/v3/forum/topics/#{topic.id}")

      assert json_response(conn, 404)
    end

    test "a hidden post never reaches the thread", %{conn: conn, forum: forum} do
      topic = topic(forum)
      [first] = Forum.list_posts(topic)
      {:ok, _hidden} = Forum.hide_post(first)

      conn = get(conn, ~p"/api/v3/forum/topics/#{topic.id}")

      assert %{"posts" => []} = json_response(conn, 200)
    end

    test "a malformed topic identifier is 404", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/forum/topics/not-a-uuid")

      assert json_response(conn, 404)
    end
  end

  describe "moderation" do
    test "PATCH /api/v3/forum/topics/:id closes and pins a topic", %{conn: conn, forum: forum} do
      topic = topic(forum)

      conn =
        conn
        |> operator_token("forum-api-close")
        |> patch(~p"/api/v3/forum/topics/#{topic.id}", %{state: "closed", pinned: true})

      assert %{"topic" => t} = json_response(conn, 200)
      assert t["state"] == "closed"
      assert t["pinned"] == true
    end

    test "PATCH /api/v3/forum/topics/:id refuses a non-operator", %{conn: conn, forum: forum} do
      topic = topic(forum)

      conn =
        conn
        |> put_forge_api_token("forum-api-close-denied")
        |> patch(~p"/api/v3/forum/topics/#{topic.id}", %{state: "closed"})

      assert json_response(conn, 403)
    end

    test "PATCH /api/v3/forum/topics/:id rejects an unknown state", %{conn: conn, forum: forum} do
      topic = topic(forum)

      conn =
        conn
        |> operator_token("forum-api-bad-state")
        |> patch(~p"/api/v3/forum/topics/#{topic.id}", %{state: "melted"})

      assert %{"errors" => %{"state" => [_message]}} = json_response(conn, 422)
    end

    test "PATCH /api/v3/forum/posts/:id hides a post", %{conn: conn, forum: forum} do
      topic = topic(forum)
      [first] = Forum.list_posts(topic)

      conn =
        conn
        |> operator_token("forum-api-hide")
        |> patch(~p"/api/v3/forum/posts/#{first.id}", %{state: "hidden"})

      assert %{"post" => %{"state" => "hidden"}} = json_response(conn, 200)
      assert Forum.list_posts(topic) == []
    end

    test "PATCH /api/v3/forum/posts/:id refuses a non-operator", %{conn: conn, forum: forum} do
      topic = topic(forum)
      [first] = Forum.list_posts(topic)

      conn =
        conn
        |> put_forge_api_token("forum-api-hide-denied")
        |> patch(~p"/api/v3/forum/posts/#{first.id}", %{state: "hidden"})

      assert json_response(conn, 403)
      assert [_post] = Forum.list_posts(topic)
    end
  end

  describe "claim review" do
    test "GET /api/v3/forum/claims/pending lists every pending claim", %{conn: conn} do
      {:ok, _claim} =
        Forum.start_actor_link(github_user("forum-api-pending-claimant"), "agent:user_2")

      conn = conn |> operator_token("forum-api-pending") |> get(~p"/api/v3/forum/claims/pending")

      assert %{"claims" => [%{"actor_ref" => "agent:user_2"}]} = json_response(conn, 200)
    end

    test "GET /api/v3/forum/claims/pending refuses a non-operator", %{conn: conn} do
      conn =
        conn
        |> put_forge_api_token("forum-api-pending-denied")
        |> get(~p"/api/v3/forum/claims/pending")

      assert json_response(conn, 403)
    end

    test "PATCH /api/v3/forum/claims/:id links a claim", %{conn: conn} do
      {:ok, claim} =
        Forum.start_actor_link(github_user("forum-api-review-claimant"), "agent:user_3")

      conn =
        conn
        |> operator_token("forum-api-review")
        |> patch(~p"/api/v3/forum/claims/#{claim.id}", %{status: "linked"})

      assert %{"claim" => %{"status" => "linked"}} = json_response(conn, 200)
    end

    test "PATCH /api/v3/forum/claims/:id is a conflict once a claim is settled", %{conn: conn} do
      {:ok, claim} =
        Forum.start_actor_link(github_user("forum-api-settled-claimant"), "agent:user_4")

      {:ok, claim} = Forum.reject_actor_link(claim)

      conn =
        conn
        |> operator_token("forum-api-settled")
        |> patch(~p"/api/v3/forum/claims/#{claim.id}", %{status: "linked"})

      assert %{"error" => "claim_not_pending"} = json_response(conn, 409)
    end
  end

  defp private_forum do
    {:ok, forum} =
      %Forum.Forum{}
      |> Forum.Forum.changeset(%{
        slug: "private",
        title: "Private",
        visibility: "private",
        discoverability: "unlisted"
      })
      |> Repo.insert()

    forum
  end

  defp operator_token(conn, key) do
    grant_operator(github_user("api-token-" <> key))
    put_forge_api_token(conn, key)
  end
end
