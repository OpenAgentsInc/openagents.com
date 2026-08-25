defmodule OpenAgentsWeb.ForumTipsLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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

  defp sign_in(conn, key) do
    user = github_user(key)
    {Plug.Test.init_test_session(conn, %{"user_id" => user.id}), user}
  end

  # Used only by the commented-out thread tipping tests below.
  #
  # defp author(forum, key) do
  #   {_conn, user} = sign_in(build_conn(), key)
  #   actor_ref = "agent:user_ed8297d8-1279-4b43-a1e7-f7867da19e20"
  #
  #   {:ok, link} = Forum.start_actor_link(user, actor_ref)
  #   {:ok, _linked} = Forum.approve_actor_link(link)
  #
  #   {:ok, destination} =
  #     Tips.register_destination(%{
  #       user_id: user.id,
  #       kind: "bolt12",
  #       destination: "lno1qsgliveauthor",
  #       label: "Phone wallet"
  #     })
  #
  #   {:ok, topic} =
  #     Forum.create_topic(forum, %{
  #       title: "Hello world",
  #       slug: "hello-world",
  #       body_text: "First post body",
  #       idempotency_key: Ecto.UUID.generate(),
  #       actor_ref: actor_ref,
  #       actor_display_name: "Orrery",
  #       actor_slug: "orrery"
  #     })
  #
  #   [post] = Forum.list_posts(topic)
  #
  #   %{user: user, destination: destination, topic: topic, post: post}
  # end

  test "a signed-in reader saves a destination and sees only its fingerprint", %{conn: conn} do
    {conn, user} = sign_in(conn, "forum-tips-live-owner")

    {:ok, view, _html} = live(conn, ~p"/forum/tips")

    html =
      view
      |> form("#tip-destination-form", %{
        destination: %{kind: "bolt12", destination: "lno1qsgowner", label: "Phone wallet"}
      })
      |> render_submit()

    destination = Tips.active_destination(user.id)

    assert html =~ destination.fingerprint
    refute html =~ "lno1qsgowner"
  end

  test "a reader opts out of tips and keeps the destination", %{conn: conn} do
    {conn, user} = sign_in(conn, "forum-tips-live-optout")

    {:ok, _destination} =
      Tips.register_destination(%{user_id: user.id, kind: "lnurl", destination: "lnurl1dp68g"})

    {:ok, view, _html} = live(conn, ~p"/forum/tips")

    render_click(view, "toggle_accepting")

    assert Tips.active_destination(user.id).accepting_tips == false
  end

  # Thread tipping is commented out in ForumTopicLive until the payment
  # service is enabled here, and these tests go with it. The API-side tip
  # tests in ForumTipsApiControllerTest still cover settlement itself.
  #
  # test "tipping a post from the thread settles and shows the new total", %{
  #   conn: conn,
  #   forum: forum
  # } do
  #   author = author(forum, "forum-tips-live-author")
  #   {conn, _payer} = sign_in(conn, "forum-tips-live-payer")
  #
  #   {:ok, view, _html} = live(conn, ~p"/forum/t/#{author.topic.id}")
  #
  #   html = render_click(view, "tip", %{"id" => author.post.id, "amount" => "1000"})
  #
  #   assert html =~ "Sent 1000 sats"
  #
  #   render_click(view, "tip", %{"id" => author.post.id, "amount" => "1000"})
  #
  #   assert Repo.reload!(author.post).tip_sats_counted == 2_000
  #   assert render(view) =~ "2000 sats"
  # end
  #
  # test "a thread never renders a payment destination", %{conn: conn, forum: forum} do
  #   author = author(forum, "forum-tips-live-privacy")
  #   {conn, _payer} = sign_in(conn, "forum-tips-live-privacy-payer")
  #
  #   {:ok, view, _html} = live(conn, ~p"/forum/t/#{author.topic.id}")
  #
  #   html = render_click(view, "tip", %{"id" => author.post.id, "amount" => "1000"})
  #
  #   refute html =~ "lno1qsgliveauthor"
  #   refute html =~ author.destination.destination
  # end
  #
  # test "a payment outage tells the payer nothing was sent", %{conn: conn, forum: forum} do
  #   author = author(forum, "forum-tips-live-outage")
  #   {conn, _payer} = sign_in(conn, "forum-tips-live-outage-payer")
  #   TipPaymentServiceStub.unavailable()
  #
  #   {:ok, view, _html} = live(conn, ~p"/forum/t/#{author.topic.id}")
  #
  #   html = render_click(view, "tip", %{"id" => author.post.id, "amount" => "1000"})
  #
  #   assert html =~ "payment service is unavailable"
  #   assert Repo.reload!(author.post).tip_sats_total == 0
  # end
end
