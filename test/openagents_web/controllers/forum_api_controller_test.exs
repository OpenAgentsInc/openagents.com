defmodule OpenAgentsWeb.ForumApiControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Forum
  alias OpenAgents.Accounts
  alias OpenAgents.Agents
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

  test "GET /api/v1/forum lists public boards", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/forum")

    assert %{"boards" => [board]} = json_response(conn, 200)
    assert board["slug"] == "general"
    assert board["title"] == "General"
  end

  test "GET /api/v1/forum/topics lists a board's topics", %{conn: conn, forum: forum} do
    topic(forum)

    conn = get(conn, ~p"/api/v1/forum/topics?forum=general")

    assert %{"topics" => [t], "pagination" => pagination} = json_response(conn, 200)
    assert t["title"] == "Hello world"
    assert t["url"] =~ "/forum/t/"
    assert pagination["total"] == 1
  end

  test "GET /api/v1/forum/topics/:id returns the thread with posts", %{conn: conn, forum: forum} do
    topic = topic(forum)

    conn = get(conn, ~p"/api/v1/forum/topics/#{topic.id}")

    assert %{"topic" => t, "posts" => posts} = json_response(conn, 200)
    assert t["title"] == "Hello world"
    assert [%{"body_text" => "First post body"}] = posts
  end

  # A topic whose id the test chooses, so a prefix can be shared or unique on
  # purpose. Inserted without posts; resolution is what these tests read.
  defp topic_with_id(forum, id) do
    {:ok, topic} =
      %Forum.Topic{}
      |> Ecto.Changeset.change(%{
        id: id,
        forum_id: forum.id,
        idempotency_key: Ecto.UUID.generate(),
        slug: "topic-#{System.unique_integer([:positive])}",
        title: "Prefixed topic",
        actor_ref: "agent:agent_artanis",
        actor_display_name: "Artanis"
      })
      |> Repo.insert()

    topic
  end

  test "GET /api/v1/forum/topics/:id resolves a unique id prefix", %{conn: conn, forum: forum} do
    topic = topic_with_id(forum, "aaaabbbb-0000-4000-8000-000000000001")

    conn = get(conn, ~p"/api/v1/forum/topics/aaaabbbb")

    assert %{"topic" => t} = json_response(conn, 200)
    assert t["id"] == topic.id
  end

  test "GET /api/v1/forum/topics/:id answers 409 for an ambiguous prefix", %{
    conn: conn,
    forum: forum
  } do
    topic_with_id(forum, "88888888-4001-4001-8001-000000000001")
    topic_with_id(forum, "88888888-4002-4002-8002-000000000002")

    conn = get(conn, ~p"/api/v1/forum/topics/88888888")

    assert %{"error" => "ambiguous_id"} = json_response(conn, 409)
  end

  test "GET /api/v1/forum/topics/:id answers 404 for a prefix that matches nothing", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/forum/topics/deadbeef")

    assert %{"error" => "not_found"} = json_response(conn, 404)
  end

  test "POST /api/v1/forum/topics creates a topic attributed to the token account", %{conn: conn} do
    conn =
      conn
      |> put_forge_api_token("forum-api-create")
      |> post(~p"/api/v1/forum/topics", %{
        forum: "general",
        title: "From the CLI",
        body_text: "Posted over the API"
      })

    assert response = json_response(conn, 201)
    assert response["topic"]["title"] == "From the CLI"
    assert hd(response["posts"])["author"]["is_agent"] == false
  end

  test "POST /api/v1/forum/topics requires authentication", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/forum/topics", %{forum: "general", title: "x", body_text: "y"})

    assert json_response(conn, 401)
  end

  test "an unlinked agent can create a topic and reply with stable attribution", %{
    conn: conn,
    forum: forum
  } do
    {:ok, agent, credential} =
      Agents.register(%{
        handle: "forum-agent",
        display_name: "Forum agent",
        registration_ip: "192.0.2.40"
      })

    topic_conn =
      conn
      |> put_req_header("authorization", "Bearer #{credential}")
      |> post(~p"/api/v1/forum/topics", %{
        forum: forum.slug,
        title: "Agent topic",
        body_text: "Created without a human link"
      })

    assert %{"topic" => topic, "posts" => [%{"author" => author}]} =
             json_response(topic_conn, 201)

    assert author["is_agent"] == true
    assert author["ref"] == "agent:#{agent.id}"
    assert author["display_name"] == agent.display_name

    topic_id = topic["id"]

    reply_conn =
      conn
      |> put_req_header("authorization", "Bearer #{credential}")
      |> post(~p"/api/v1/forum/topics/#{topic_id}/posts", %{
        body_text: "Agent reply"
      })

    assert %{"post" => %{"author" => %{"is_agent" => true, "ref" => "agent:" <> _}}} =
             json_response(reply_conn, 201)
  end

  test "POST /api/v1/forum/topics/:id/posts replies to a topic", %{conn: conn, forum: forum} do
    topic = topic(forum)

    conn =
      conn
      |> put_forge_api_token("forum-api-reply")
      |> post(~p"/api/v1/forum/topics/#{topic.id}/posts", %{body_text: "API reply"})

    assert %{"post" => post} = json_response(conn, 201)
    assert post["post_number"] == 2
    assert Forum.count_posts(topic) == 2
  end

  test "a suspended agent is refused on the forum reply route", %{conn: conn, forum: forum} do
    {:ok, topic} =
      Forum.create_topic(forum, %{
        title: "Suspended target",
        slug: "suspended-target",
        body_text: "Existing topic",
        idempotency_key: Ecto.UUID.generate(),
        actor_ref: "agent:suspended",
        actor_display_name: "Suspended",
        actor_slug: "suspended"
      })

    {:ok, agent, credential} =
      Agents.register(%{
        handle: "suspended-forum-bot",
        display_name: "Suspended forum bot",
        registration_ip: "192.0.2.41"
      })

    assert {:ok, _suspended} = Agents.suspend(agent, "test")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{credential}")
      |> post(~p"/api/v1/forum/topics/#{topic.id}/posts", %{body_text: "Should fail"})

    assert conn.status == 401
  end

  test "linking and unlinking do not rewrite forum authorship", %{conn: conn, forum: forum} do
    {:ok, agent, credential} =
      Agents.register(%{
        handle: "stable-forum-bot",
        display_name: "Stable forum bot",
        registration_ip: "192.0.2.42"
      })

    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: 992_042,
        github_login: "stable-forum-reviewer",
        github_avatar_url: "https://avatars.githubusercontent.com/u/992042?v=4"
      })

    created =
      conn
      |> put_req_header("authorization", "Bearer #{credential}")
      |> post(~p"/api/v1/forum/topics", %{
        forum: forum.slug,
        title: "Stable topic",
        body_text: "Authorship must remain stable"
      })

    assert %{"topic" => %{"id" => topic_id}} = json_response(created, 201)
    before = get(conn, ~p"/api/v1/forum/topics/#{topic_id}") |> json_response(200)

    assert {:ok, pending} = Agents.request_link(agent, user)
    assert {:ok, _linked} = Agents.accept_link(user, pending.id)
    assert {:ok, _unlinked} = Agents.unlink(agent, user)

    after_link = get(conn, ~p"/api/v1/forum/topics/#{topic_id}") |> json_response(200)
    assert before["topic"]["actor_ref"] == after_link["topic"]["actor_ref"]
    assert before["topic"]["actor_display_name"] == after_link["topic"]["actor_display_name"]
    assert before["topic"]["actor_slug"] == after_link["topic"]["actor_slug"]
    assert before["posts"] == after_link["posts"]

    profile = get(conn, ~p"/api/v1/agents/#{agent.handle}") |> json_response(200)
    refute Map.has_key?(profile["agent"], "owner")
  end

  test "POST /api/v1/forum/claims starts an identity claim", %{conn: conn} do
    conn =
      conn
      |> put_forge_api_token("forum-api-claim")
      |> post(~p"/api/v1/forum/claims", %{
        actor_ref: "agent:user_ed8297d8-1279-4b43-a1e7-f7867da19e20"
      })

    assert %{"claim" => %{"status" => "pending"}} = json_response(conn, 201)
  end

  test "GET /api/v1/forum/claims lists the caller's claims", %{conn: conn} do
    authed = put_forge_api_token(conn, "forum-api-list-claims")

    {:ok, _} =
      Forum.start_actor_link(github_user("api-token-forum-api-list-claims"), "agent:user_1")

    _ = authed

    conn = get(authed, ~p"/api/v1/forum/claims")

    assert %{"claims" => claims} = json_response(conn, 200)
    assert length(claims) >= 1
  end

  test "unknown board is 404", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/forum/topics?forum=nope")

    assert json_response(conn, 404)
  end

  describe "search" do
    test "matches a topic title across every readable board", %{conn: conn, forum: forum} do
      topic(forum, %{title: "Router latency", slug: "router-latency"})
      topic(forum, %{title: "Something else", slug: "something-else"})

      conn = get(conn, ~p"/api/v1/forum/topics?q=latency")

      assert %{"query" => "latency", "topics" => [t], "board" => nil} = json_response(conn, 200)
      assert t["title"] == "Router latency"
      assert t["board"]["slug"] == "general"
    end

    test "matches a visible post body", %{conn: conn, forum: forum} do
      topic(forum, %{title: "Deploy notes", slug: "deploy-notes", body_text: "watch the walrus"})

      conn = get(conn, ~p"/api/v1/forum/topics?q=walrus")

      assert %{"topics" => [t]} = json_response(conn, 200)
      assert t["title"] == "Deploy notes"
    end

    test "matches a topic author's display name and slug", %{conn: conn, forum: forum} do
      topic(forum, %{
        title: "Release notes",
        slug: "release-notes",
        actor_display_name: "Fable Coder",
        actor_slug: "fable-coder"
      })

      topic(forum, %{title: "Unrelated", slug: "unrelated"})

      by_name = get(conn, ~p"/api/v1/forum/topics?q=fable")
      assert %{"topics" => [t]} = json_response(by_name, 200)
      assert t["title"] == "Release notes"

      by_slug = get(conn, ~p"/api/v1/forum/topics?q=fable-coder")
      assert %{"topics" => [_]} = json_response(by_slug, 200)
    end

    test "matches a visible reply's author", %{conn: conn, forum: forum} do
      topic = topic(forum, %{title: "Quiet thread", slug: "quiet-thread"})

      {:ok, _post} =
        Forum.create_post(topic, %{
          body_text: "checking in",
          actor_ref: "agent:fable-reply-bot",
          actor_display_name: "Fable reply bot",
          actor_slug: "fable-reply-bot",
          idempotency_key: Ecto.UUID.generate()
        })

      conn = get(conn, ~p"/api/v1/forum/topics?q=fable")

      assert %{"topics" => [t]} = json_response(conn, 200)
      assert t["title"] == "Quiet thread"
    end

    test "stays inside one board when given a board", %{conn: conn, forum: forum} do
      {:ok, other} =
        %Forum.Forum{}
        |> Forum.Forum.changeset(%{slug: "meta", title: "Meta"})
        |> Repo.insert()

      topic(forum, %{title: "Shared word here", slug: "shared-general"})
      topic(other, %{title: "Shared word there", slug: "shared-meta"})

      conn = get(conn, ~p"/api/v1/forum/topics?forum=meta&q=shared")

      assert %{"topics" => [t], "board" => board} = json_response(conn, 200)
      assert board["slug"] == "meta"
      assert t["title"] == "Shared word there"
    end

    test "never returns a private board's topics to an anonymous caller", %{conn: conn} do
      private = private_forum()
      topic(private, %{title: "Private plan", slug: "private-plan"})

      conn = get(conn, ~p"/api/v1/forum/topics?q=private")

      assert %{"topics" => []} = json_response(conn, 200)
    end

    test "returns a private board's topics to an operator", %{conn: conn} do
      private = private_forum()
      topic(private, %{title: "Private plan", slug: "private-plan"})

      conn =
        conn
        |> operator_token("forum-api-search-operator")
        |> get(~p"/api/v1/forum/topics?q=private")

      assert %{"topics" => [t]} = json_response(conn, 200)
      assert t["title"] == "Private plan"
    end
  end

  describe "authorization of reads" do
    test "GET /api/v1/forum omits a private board", %{conn: conn} do
      private_forum()

      conn = get(conn, ~p"/api/v1/forum")

      assert %{"boards" => boards} = json_response(conn, 200)
      assert Enum.map(boards, & &1["slug"]) == ["general"]
    end

    test "GET /api/v1/forum lists a private board for an operator", %{conn: conn} do
      private_forum()

      conn = conn |> operator_token("forum-api-boards-operator") |> get(~p"/api/v1/forum")

      assert %{"boards" => boards} = json_response(conn, 200)
      assert "private" in Enum.map(boards, & &1["slug"])
    end

    test "a private board's topic list is 404 for an anonymous caller", %{conn: conn} do
      private_forum()

      conn = get(conn, ~p"/api/v1/forum/topics?forum=private")

      assert json_response(conn, 404)
    end

    test "a private board's thread is 404 for an anonymous caller", %{conn: conn} do
      topic = topic(private_forum(), %{title: "Private plan", slug: "private-plan"})

      conn = get(conn, ~p"/api/v1/forum/topics/#{topic.id}")

      assert json_response(conn, 404)
    end

    test "a hidden post never reaches the thread", %{conn: conn, forum: forum} do
      topic = topic(forum)
      [first] = Forum.list_posts(topic)
      {:ok, _hidden} = Forum.hide_post(first)

      conn = get(conn, ~p"/api/v1/forum/topics/#{topic.id}")

      assert %{"posts" => []} = json_response(conn, 200)
    end

    test "a malformed topic identifier is 404", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/forum/topics/not-a-uuid")

      assert json_response(conn, 404)
    end
  end

  describe "moderation" do
    test "PATCH /api/v1/forum/topics/:id closes and pins a topic", %{conn: conn, forum: forum} do
      topic = topic(forum)

      conn =
        conn
        |> operator_token("forum-api-close")
        |> patch(~p"/api/v1/forum/topics/#{topic.id}", %{state: "closed", pinned: true})

      assert %{"topic" => t} = json_response(conn, 200)
      assert t["state"] == "closed"
      assert t["pinned"] == true
    end

    test "PATCH /api/v1/forum/topics/:id refuses a non-operator", %{conn: conn, forum: forum} do
      topic = topic(forum)

      conn =
        conn
        |> put_forge_api_token("forum-api-close-denied")
        |> patch(~p"/api/v1/forum/topics/#{topic.id}", %{state: "closed"})

      assert json_response(conn, 403)
    end

    test "PATCH /api/v1/forum/topics/:id rejects an unknown state", %{conn: conn, forum: forum} do
      topic = topic(forum)

      conn =
        conn
        |> operator_token("forum-api-bad-state")
        |> patch(~p"/api/v1/forum/topics/#{topic.id}", %{state: "melted"})

      assert %{"errors" => %{"state" => [_message]}} = json_response(conn, 422)
    end

    test "PATCH /api/v1/forum/posts/:id hides a post", %{conn: conn, forum: forum} do
      topic = topic(forum)
      [first] = Forum.list_posts(topic)

      conn =
        conn
        |> operator_token("forum-api-hide")
        |> patch(~p"/api/v1/forum/posts/#{first.id}", %{state: "hidden"})

      assert %{"post" => %{"state" => "hidden"}} = json_response(conn, 200)
      assert Forum.list_posts(topic) == []
    end

    test "PATCH /api/v1/forum/posts/:id refuses a non-operator", %{conn: conn, forum: forum} do
      topic = topic(forum)
      [first] = Forum.list_posts(topic)

      conn =
        conn
        |> put_forge_api_token("forum-api-hide-denied")
        |> patch(~p"/api/v1/forum/posts/#{first.id}", %{state: "hidden"})

      assert json_response(conn, 403)
      assert [_post] = Forum.list_posts(topic)
    end
  end

  describe "claim review" do
    test "GET /api/v1/forum/claims/pending lists every pending claim", %{conn: conn} do
      {:ok, _claim} =
        Forum.start_actor_link(github_user("forum-api-pending-claimant"), "agent:user_2")

      conn = conn |> operator_token("forum-api-pending") |> get(~p"/api/v1/forum/claims/pending")

      assert %{"claims" => [%{"actor_ref" => "agent:user_2"}]} = json_response(conn, 200)
    end

    test "GET /api/v1/forum/claims/pending refuses a non-operator", %{conn: conn} do
      conn =
        conn
        |> put_forge_api_token("forum-api-pending-denied")
        |> get(~p"/api/v1/forum/claims/pending")

      assert json_response(conn, 403)
    end

    test "PATCH /api/v1/forum/claims/:id links a claim", %{conn: conn} do
      {:ok, claim} =
        Forum.start_actor_link(github_user("forum-api-review-claimant"), "agent:user_3")

      conn =
        conn
        |> operator_token("forum-api-review")
        |> patch(~p"/api/v1/forum/claims/#{claim.id}", %{status: "linked"})

      assert %{"claim" => %{"status" => "linked"}} = json_response(conn, 200)
    end

    test "PATCH /api/v1/forum/claims/:id is a conflict once a claim is settled", %{conn: conn} do
      {:ok, claim} =
        Forum.start_actor_link(github_user("forum-api-settled-claimant"), "agent:user_4")

      {:ok, claim} = Forum.reject_actor_link(claim)

      conn =
        conn
        |> operator_token("forum-api-settled")
        |> patch(~p"/api/v1/forum/claims/#{claim.id}", %{status: "linked"})

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
