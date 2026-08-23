defmodule OpenAgentsWeb.NotificationsLiveTest do
  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OpenAgents.Issues
  alias OpenAgents.Notifications
  alias OpenAgents.Repositories

  defp setup_thread(conn, visibility) do
    reader = github_user("notifications-reader", "notifications-reader")
    actor = github_user("notifications-actor", "notifications-actor")

    {:ok, repository} =
      Repositories.create_repository(%{
        owner: "NotifyOrg",
        name: "notify-#{System.unique_integer([:positive])}",
        visibility: visibility,
        default_branch: "main"
      })

    {:ok, _reader_membership} = Repositories.add_member(repository, reader, "owner")
    {:ok, _actor_membership} = Repositories.add_member(repository, actor, "contributor")

    {:ok, issue} = Issues.create_issue(repository, %{title: "A tracked issue"}, reader)
    {:ok, _comment} = Issues.create_comment(issue, %{"body" => "an update"}, actor)

    conn = Plug.Test.init_test_session(conn, %{"user_id" => reader.id})

    %{conn: conn, reader: reader, actor: actor, repository: repository, issue: issue}
  end

  describe "the inbox" do
    test "shows a notification about an issue the reader can read", %{conn: conn} do
      %{conn: conn} = setup_thread(conn, "public")

      {:ok, view, _html} = live(conn, ~p"/notifications")

      assert has_element?(view, "#notifications-list")
      assert has_element?(view, "#notifications-unread-count")
      refute has_element?(view, "#notifications-empty")
    end

    test "shows an empty state for an account with nothing waiting", %{conn: conn} do
      conn = log_in_github_user(conn, "quiet-account")

      {:ok, view, _html} = live(conn, ~p"/notifications")

      assert has_element?(view, "#notifications-empty")
      refute has_element?(view, "#notifications-unread-count")
    end

    test "marking one read clears the unread badge", %{conn: conn} do
      %{conn: conn, reader: reader} = setup_thread(conn, "public")

      {:ok, view, _html} = live(conn, ~p"/notifications")

      [notification] = Notifications.list_notifications(reader)

      view |> element("#mark-read-#{notification.id}") |> render_click()

      refute has_element?(view, "#notifications-unread-count")
      assert Notifications.unread_count(reader) == 0
    end

    test "mark all read clears every unread record", %{conn: conn} do
      %{conn: conn, reader: reader, issue: issue, actor: actor} = setup_thread(conn, "public")
      {:ok, _second} = Issues.create_comment(issue, %{"body" => "and another"}, actor)

      {:ok, view, _html} = live(conn, ~p"/notifications")

      assert Notifications.unread_count(reader) == 2

      view |> element("#notifications-mark-all-read") |> render_click()

      refute has_element?(view, "#notifications-mark-all-read")
      assert Notifications.unread_count(reader) == 0
    end

    test "an anonymous visitor is sent to sign in", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/notifications")
      refute path == ~p"/notifications"
    end
  end

  describe "authorization" do
    test "a private repository notification disappears when membership ends", %{conn: conn} do
      %{conn: conn, reader: reader, actor: actor, repository: repository} =
        setup_thread(conn, "private")

      {:ok, view, _html} = live(conn, ~p"/notifications")
      assert has_element?(view, "#notifications-list")
      refute has_element?(view, "#notifications-empty")

      # `actor` is the remaining owner, so removing the reader leaves an owner
      # behind and the guard against removing the last one does not fire.
      {:ok, _promoted} = Repositories.add_member(repository, actor, "owner")
      :ok = Repositories.remove_member(repository, actor, reader.id)

      {:ok, view, _html} = live(conn, ~p"/notifications")

      assert has_element?(view, "#notifications-empty")
      refute has_element?(view, "#notifications-unread-count")
    end

    test "the inbox never renders another account's notifications", %{conn: conn} do
      %{issue: issue, actor: actor} = setup_thread(conn, "public")

      stranger = github_user("notifications-stranger", "notifications-stranger")
      {:ok, _comment} = Issues.create_comment(issue, %{"body" => "more"}, actor)

      conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => stranger.id})
      {:ok, view, _html} = live(conn, ~p"/notifications")

      assert has_element?(view, "#notifications-empty")
    end
  end

  describe "preference controls" do
    test "turning a category off is recorded", %{conn: conn} do
      %{conn: conn, reader: reader} = setup_thread(conn, "public")

      {:ok, view, _html} = live(conn, ~p"/notifications")

      view
      |> form("#notification-preferences-form", %{
        "preferences" => %{
          "mentions_enabled" => "true",
          "issue_comments_enabled" => "false"
        }
      })
      |> render_change()

      preferences = Notifications.preferences(reader)

      assert preferences.mentions_enabled
      refute preferences.issue_comments_enabled
    end

    test "turning a category back on is recorded", %{conn: conn} do
      %{conn: conn, reader: reader} = setup_thread(conn, "public")
      {:ok, _off} = Notifications.update_preferences(reader, %{mentions_enabled: false})

      {:ok, view, _html} = live(conn, ~p"/notifications")

      view
      |> form("#notification-preferences-form", %{
        "preferences" => %{
          "mentions_enabled" => "true",
          "issue_comments_enabled" => "true"
        }
      })
      |> render_change()

      assert Notifications.preferences(reader).mentions_enabled
    end
  end

  describe "the subscribe control on an issue" do
    test "an author can unsubscribe and subscribe again", %{conn: conn} do
      %{conn: conn, reader: reader, repository: repository, issue: issue} =
        setup_thread(conn, "public")

      assert Notifications.subscribed?(issue, reader)

      {:ok, view, _html} =
        live(conn, ~p"/#{repository.owner}/#{repository.name}/issues/#{issue.number}")

      view |> element("#issue-subscription-toggle") |> render_click()
      refute Notifications.subscribed?(issue, reader)

      view |> element("#issue-subscription-toggle") |> render_click()
      assert Notifications.subscribed?(issue, reader)
    end

    test "an anonymous visitor sees no subscribe control", %{conn: conn} do
      %{repository: repository, issue: issue} = setup_thread(conn, "public")

      {:ok, view, _html} =
        live(build_conn(), ~p"/#{repository.owner}/#{repository.name}/issues/#{issue.number}")

      refute has_element?(view, "#issue-subscription-toggle")
    end
  end

  describe "the sidebar unread badge" do
    test "counts what is waiting and links to the inbox", %{conn: conn} do
      %{conn: conn} = setup_thread(conn, "public")

      {:ok, view, _html} = live(conn, ~p"/notifications")

      assert has_element?(view, "#sidebar-badge-notifications", "1")
    end

    test "renders nothing at zero", %{conn: conn} do
      conn = log_in_github_user(conn, "quiet-badge-account")

      {:ok, view, _html} = live(conn, ~p"/notifications")

      refute has_element?(view, "#sidebar-badge-notifications")
    end

    test "appears on a page that is not the inbox", %{conn: conn} do
      %{conn: conn} = setup_thread(conn, "public")

      {:ok, view, _html} = live(conn, ~p"/issues")

      assert has_element?(view, "#sidebar-badge-notifications", "1")
    end

    test "counts up when a notification arrives, without a reload", %{conn: conn} do
      %{conn: conn, issue: issue, actor: actor} = setup_thread(conn, "public")

      {:ok, view, _html} = live(conn, ~p"/issues")
      assert has_element?(view, "#sidebar-badge-notifications", "1")

      {:ok, _second} = Issues.create_comment(issue, %{"body" => "and another"}, actor)

      assert has_element?(view, "#sidebar-badge-notifications", "2")
    end

    test "clears when the inbox is marked read, without a reload", %{conn: conn} do
      %{conn: conn, reader: reader} = setup_thread(conn, "public")

      {:ok, view, _html} = live(conn, ~p"/notifications")
      assert has_element?(view, "#sidebar-badge-notifications", "1")

      [notification] = Notifications.list_notifications(reader)
      view |> element("#mark-read-#{notification.id}") |> render_click()

      refute has_element?(view, "#sidebar-badge-notifications")
    end

    test "one account's badge never counts another account's inbox", %{conn: conn} do
      %{issue: issue, actor: actor} = setup_thread(conn, "public")

      stranger = github_user("badge-stranger", "badge-stranger")
      stranger_conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => stranger.id})

      {:ok, view, _html} = live(stranger_conn, ~p"/issues")

      {:ok, _second} = Issues.create_comment(issue, %{"body" => "not for you"}, actor)

      refute has_element?(view, "#sidebar-badge-notifications")
    end
  end
end
