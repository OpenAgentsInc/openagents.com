defmodule OpenAgentsWeb.ForumLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Forum
  alias OpenAgents.Repo

  defp user(conn, key) do
    {conn, user} = log_in_user_returning_user(conn, key)
    {conn, user}
  end

  defp log_in_user_returning_user(conn, key) do
    user = github_user(key)
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    {conn, user}
  end

  defp forum do
    {:ok, forum} =
      %Forum.Forum{}
      |> Forum.Forum.changeset(%{
        slug: "general",
        title: "General",
        description: "Everything else"
      })
      |> Repo.insert()

    forum
  end

  defp topic(forum) do
    {:ok, topic} =
      Forum.create_topic(forum, %{
        title: "Hello world",
        slug: "hello-world",
        body_text: "First post body",
        idempotency_key: Ecto.UUID.generate(),
        actor_ref: "agent:user_ed8297d8-1279-4b43-a1e7-f7867da19e20",
        actor_display_name: "Orrery",
        actor_slug: "orrery"
      })

    topic
  end

  test "home lists boards", %{conn: conn} do
    _forum = forum()
    {conn, _user} = user(conn, "forum-home")
    {:ok, _view, html} = live(conn, ~p"/forum")
    assert html =~ "General"
  end

  test "board lists topics and shows the composer", %{conn: conn} do
    forum = forum()
    topic(forum)

    {conn, _user} = user(conn, "forum-board")

    {:ok, view, html} = live(conn, ~p"/forum/f/general")
    assert html =~ "General"
    assert has_element?(view, "#topics")
    assert html =~ "Hello world"
    assert has_element?(view, "#new-topic-form")
  end

  test "a topic renders its posts and a reply form", %{conn: conn} do
    forum = forum()
    topic = topic(forum)

    {conn, _user} = user(conn, "forum-thread")

    {:ok, view, html} = live(conn, ~p"/forum/t/#{topic.id}")
    assert html =~ "First post body"
    assert has_element?(view, "#reply-form")
  end

  test "replying appends a post to the stream", %{conn: conn} do
    forum = forum()
    topic = topic(forum)

    {conn, _user} = user(conn, "forum-reply")
    {:ok, view, _html} = live(conn, ~p"/forum/t/#{topic.id}")

    view
    |> form("#reply-form", post: %{body_text: "A reply from the test"})
    |> render_submit()

    assert render(view) =~ "A reply from the test"
    assert Forum.count_posts(topic) == 2
  end

  test "anonymous readers reach forum pages and boards carry og metadata", %{conn: conn} do
    forum = forum()
    topic = topic(forum)

    {:ok, _view, home_html} = live(conn, ~p"/forum")
    assert home_html =~ "General"

    board_html = conn |> get(~p"/forum/f/general") |> html_response(200)
    assert board_html =~ ~s(property="og:image")
    assert board_html =~ "/og/v/"

    topic_html = conn |> get(~p"/forum/t/#{topic.id}") |> html_response(200)
    assert topic_html =~ ~s(property="og:image")
    assert topic_html =~ "Hello world"
  end

  # #23: the cutover keeps every legacy link working without a redirect table.
  # The import wrote each legacy row's own UUID into the primary key, so the
  # legacy `/forum/t/<topic-id>` is the path this application already serves.
  # This asserts the URL, not just the lookup, and asserts it for a visitor.
  test "a link written against the legacy forum lands on the topic it named", %{conn: conn} do
    board = forum()
    legacy_id = "2c5f1e98-4b1f-4a2a-9c3d-000000000023"

    topic =
      Repo.insert!(%Forum.Topic{
        id: legacy_id,
        forum_id: board.id,
        idempotency_key: legacy_id,
        slug: "ported-from-the-legacy-forum",
        title: "Ported from the legacy forum",
        actor_ref: "agent:user_0123abcd",
        actor_display_name: "Artanis",
        state: "open",
        pin_state: "normal",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      })

    html = conn |> get("/forum/t/#{legacy_id}") |> html_response(200)

    assert html =~ "Ported from the legacy forum"
    assert topic.id == legacy_id
  end
end
