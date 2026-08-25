defmodule OpenAgentsWeb.ForumTipsApiControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Forum
  alias OpenAgents.Forum.{TipPaymentServiceStub, Tips}
  alias OpenAgents.Repo

  setup %{conn: conn} do
    TipPaymentServiceStub.settle()

    {:ok, forum} =
      %Forum.Forum{}
      |> Forum.Forum.changeset(%{slug: "general", title: "General"})
      |> Repo.insert()

    {:ok, conn: conn, forum: forum}
  end

  # An author who holds the linked identity and its own payment destination.
  defp author(forum) do
    # The same key `put_forge_api_token/2` derives its user from, so the test
    # can also call the API as the author.
    user = github_user("api-token-forum-tips-author")
    actor_ref = "agent:user_ed8297d8-1279-4b43-a1e7-f7867da19e20"

    {:ok, link} = Forum.start_actor_link(user, actor_ref)
    {:ok, _linked} = Forum.approve_actor_link(link)

    {:ok, destination} =
      Tips.register_destination(%{
        user_id: user.id,
        kind: "bolt12",
        destination: "lno1qsgauthor",
        label: "Phone wallet"
      })

    {:ok, topic} =
      Forum.create_topic(forum, %{
        title: "Hello world",
        slug: "hello-world",
        body_text: "First post body",
        idempotency_key: Ecto.UUID.generate(),
        actor_ref: actor_ref,
        actor_display_name: "Orrery",
        actor_slug: "orrery"
      })

    [post] = Forum.list_posts(topic)

    %{user: user, destination: destination, topic: topic, post: post}
  end

  describe "destinations" do
    test "a caller registers a destination and reads back only its fingerprint", %{conn: conn} do
      authed = put_forge_api_token(conn, "forum-tips-destination")

      created =
        post(authed, ~p"/api/v1/forum/tips/destination", %{
          kind: "bolt12",
          destination: "lno1qsgpayer",
          label: "Phone wallet"
        })

      assert %{"destination" => destination} = json_response(created, 201)
      assert destination["kind"] == "bolt12"
      assert destination["custody"] == "self"
      assert destination["accepting_tips"] == true
      assert is_binary(destination["fingerprint"])
      refute Map.has_key?(destination, "destination")

      read =
        conn
        |> put_forge_api_token("forum-tips-destination")
        |> get(~p"/api/v1/forum/tips/destination")

      assert %{"destination" => same} = json_response(read, 200)
      assert same["fingerprint"] == destination["fingerprint"]
      refute Map.has_key?(same, "destination")
    end

    test "a caller opts out of tips without deleting the destination", %{conn: conn} do
      authed = put_forge_api_token(conn, "forum-tips-optout")

      post(authed, ~p"/api/v1/forum/tips/destination", %{
        kind: "lnurl",
        destination: "lnurl1dp68gurn8ghj7"
      })

      updated =
        patch(
          put_forge_api_token(conn, "forum-tips-optout"),
          ~p"/api/v1/forum/tips/destination",
          %{accepting_tips: false}
        )

      assert %{"destination" => destination} = json_response(updated, 200)
      assert destination["accepting_tips"] == false
      assert destination["state"] == "active"
    end

    test "the destination endpoints need a bearer token", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/v1/forum/tips/destination"), 401)

      assert json_response(
               post(conn, ~p"/api/v1/forum/tips/destination", %{
                 kind: "bolt12",
                 destination: "lno1x"
               }),
               401
             )
    end
  end

  describe "tips" do
    test "a tip settles and returns its counted weight", %{conn: conn, forum: forum} do
      author = author(forum)

      created =
        conn
        |> put_forge_api_token("forum-tips-payer")
        |> post(~p"/api/v1/forum/posts/#{author.post.id}/tips", %{
          amount_sats: 1_000,
          idempotency_key: Ecto.UUID.generate()
        })

      assert %{"tip" => tip, "receipts" => [receipt]} = json_response(created, 201)
      assert tip["state"] == "settled"
      assert tip["amount_sats"] == 1_000
      assert tip["counted_sats"] == 1_000
      assert tip["excluded_from_ranking"] == false
      assert receipt["kind"] == "settled"
      assert is_binary(receipt["payment_hash"])
    end

    test "a retry with the same key returns the same tip", %{conn: conn, forum: forum} do
      author = author(forum)
      key = Ecto.UUID.generate()

      first =
        conn
        |> put_forge_api_token("forum-tips-retry")
        |> post(~p"/api/v1/forum/posts/#{author.post.id}/tips", %{
          amount_sats: 400,
          idempotency_key: key
        })

      second =
        conn
        |> put_forge_api_token("forum-tips-retry")
        |> post(~p"/api/v1/forum/posts/#{author.post.id}/tips", %{
          amount_sats: 400,
          idempotency_key: key
        })

      assert json_response(first, 201)["tip"]["id"] == json_response(second, 201)["tip"]["id"]
      assert [_one_payment] = TipPaymentServiceStub.requests()
      assert Repo.reload!(author.post).tip_sats_total == 400
    end

    test "a failed payment answers 402 and counts nothing", %{conn: conn, forum: forum} do
      author = author(forum)
      TipPaymentServiceStub.fail("no_route")

      created =
        conn
        |> put_forge_api_token("forum-tips-failed")
        |> post(~p"/api/v1/forum/posts/#{author.post.id}/tips", %{
          amount_sats: 100,
          idempotency_key: Ecto.UUID.generate()
        })

      assert %{"tip" => tip} = json_response(created, 402)
      assert tip["state"] == "failed"
      assert tip["failure_code"] == "no_route"
      assert tip["counted_sats"] == 0
      assert Repo.reload!(author.post).tip_sats_counted == 0
    end

    test "an unavailable payment service answers 503 and keeps reads working", %{
      conn: conn,
      forum: forum
    } do
      author = author(forum)
      TipPaymentServiceStub.unavailable()

      created =
        conn
        |> put_forge_api_token("forum-tips-outage")
        |> post(~p"/api/v1/forum/posts/#{author.post.id}/tips", %{
          amount_sats: 100,
          idempotency_key: Ecto.UUID.generate()
        })

      assert json_response(created, 503)["error"]

      listed = get(conn, ~p"/api/v1/forum/topics?forum=general")
      assert [topic] = json_response(listed, 200)["topics"]
      assert topic["tip_sats"] == 0
    end

    test "tipping needs a bearer token", %{conn: conn, forum: forum} do
      author = author(forum)

      assert json_response(
               post(conn, ~p"/api/v1/forum/posts/#{author.post.id}/tips", %{amount_sats: 100}),
               401
             )
    end

    test "an unknown post is 404", %{conn: conn} do
      created =
        conn
        |> put_forge_api_token("forum-tips-missing")
        |> post(~p"/api/v1/forum/posts/#{Ecto.UUID.generate()}/tips", %{
          amount_sats: 100,
          idempotency_key: Ecto.UUID.generate()
        })

      assert json_response(created, 404)
    end
  end

  describe "received tips" do
    test "a recipient lists settlements it can verify in its own wallet", %{
      conn: conn,
      forum: forum
    } do
      author = author(forum)

      conn
      |> put_forge_api_token("forum-tips-recipient-payer")
      |> post(~p"/api/v1/forum/posts/#{author.post.id}/tips", %{
        amount_sats: 900,
        idempotency_key: Ecto.UUID.generate()
      })
      |> json_response(201)

      listed =
        conn
        |> put_forge_api_token("forum-tips-author")
        |> get(~p"/api/v1/forum/tips/received")

      export = json_response(listed, 200)
      assert export["custody"] == "self"
      assert export["received_sats"] == 900
      assert export["destination_fingerprint"] == author.destination.fingerprint
      refute export["destination"]
      assert [settlement] = export["settlements"]
      assert is_binary(settlement["payment_hash"])
    end
  end

  describe "public projections" do
    test "public pages show bounded totals and never a destination", %{conn: conn, forum: forum} do
      author = author(forum)

      conn
      |> put_forge_api_token("forum-tips-public")
      |> post(~p"/api/v1/forum/posts/#{author.post.id}/tips", %{
        amount_sats: 1_500,
        idempotency_key: Ecto.UUID.generate()
      })
      |> json_response(201)

      thread = get(conn, ~p"/api/v1/forum/topics/#{author.topic.id}")
      body = response(thread, 200)

      assert %{"topic" => topic, "posts" => [post]} = Jason.decode!(body)
      assert topic["tip_sats"] == 1_500
      assert post["tip_sats"] == 1_500
      assert post["tip_count"] == 1
      refute body =~ "lno1qsgauthor"
      refute body =~ "destination"
    end
  end
end
