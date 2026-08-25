defmodule OpenAgentsWeb.NotificationsLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Accounts.User
  alias OpenAgents.Issues
  alias OpenAgents.Notifications
  alias OpenAgents.Notifications.EmailChannel
  alias OpenAgents.Repo
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

  describe "the email channel" do
    test "an address is taken, and is not a recipient until the code comes back", %{conn: conn} do
      %{conn: conn, reader: reader} = setup_thread(conn, "public")

      {:ok, view, _html} = live(conn, ~p"/notifications")

      assert has_element?(view, "#notification-email-address-form")
      refute has_element?(view, "#notification-email-code-form")
      refute has_element?(view, "#notification-email-channel-form")

      view
      |> form("#notification-email-address-form", %{"email" => %{"address" => "me@example.com"}})
      |> render_submit()

      pending = Repo.get!(User, reader.id)
      assert pending.notification_email == "me@example.com"
      assert EmailChannel.verified_address(pending) == nil

      # The switch that would turn the channel on is not offered yet, because
      # there is nowhere for it to send.
      assert has_element?(view, "#notification-email-code-form")
      refute has_element?(view, "#notification-email-channel-form")

      assert_receive {:email, %Swoosh.Email{subject: subject}}
      code = hd(Regex.run(~r/[0-9A-Z]{8}/, subject))

      view
      |> form("#notification-email-code-form", %{"email" => %{"code" => code}})
      |> render_submit()

      assert EmailChannel.verified_address(Repo.get!(User, reader.id)) == "me@example.com"
      assert has_element?(view, "#notification-email-channel-form")
      assert has_element?(view, "#notification-email-verified")
    end

    test "a wrong code leaves the address unverified", %{conn: conn} do
      %{conn: conn, reader: reader} = setup_thread(conn, "public")

      {:ok, view, _html} = live(conn, ~p"/notifications")

      view
      |> form("#notification-email-address-form", %{"email" => %{"address" => "me@example.com"}})
      |> render_submit()

      html =
        view
        |> form("#notification-email-code-form", %{"email" => %{"code" => "00000000"}})
        |> render_submit()

      assert html =~ "not right"
      assert EmailChannel.verified_address(Repo.get!(User, reader.id)) == nil
    end

    test "the channel switch is off until the account turns it on", %{conn: conn} do
      %{conn: conn, reader: reader} = setup_thread(conn, "public")

      {:ok, pending} = EmailChannel.set_address(reader, "me@example.com")
      assert_receive {:email, %Swoosh.Email{subject: subject}}
      {:ok, _verified} = EmailChannel.verify(pending, hd(Regex.run(~r/[0-9A-Z]{8}/, subject)))

      refute Notifications.preferences(reader).email_enabled

      {:ok, view, _html} = live(conn, ~p"/notifications")

      view
      |> form("#notification-email-channel-form", %{"channel" => %{"email_enabled" => "true"}})
      |> render_change()

      assert Notifications.preferences(reader).email_enabled
    end

    test "removing the address takes the switch with it", %{conn: conn} do
      %{conn: conn, reader: reader} = setup_thread(conn, "public")

      {:ok, pending} = EmailChannel.set_address(reader, "me@example.com")
      assert_receive {:email, %Swoosh.Email{subject: subject}}
      {:ok, _verified} = EmailChannel.verify(pending, hd(Regex.run(~r/[0-9A-Z]{8}/, subject)))

      {:ok, view, _html} = live(conn, ~p"/notifications")
      assert has_element?(view, "#notification-email-channel-form")

      view |> element("#notification-email-remove") |> render_click()

      refute has_element?(view, "#notification-email-channel-form")
      assert EmailChannel.verified_address(Repo.get!(User, reader.id)) == nil
    end

    test "a deployment with no mail provider collects no address at all", %{conn: conn} do
      configured = Application.get_env(:openagents, EmailChannel)
      Application.put_env(:openagents, EmailChannel, Keyword.put(configured, :deliverable, false))
      on_exit(fn -> Application.put_env(:openagents, EmailChannel, configured) end)

      %{conn: conn} = setup_thread(conn, "public")

      {:ok, view, _html} = live(conn, ~p"/notifications")

      assert has_element?(view, "#notifications-email-unavailable")
      refute has_element?(view, "#notification-email-address-form")
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
end
