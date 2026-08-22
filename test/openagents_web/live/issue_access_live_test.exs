defmodule OpenAgentsWeb.IssueAccessLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Accounts
  alias OpenAgents.Issues
  alias OpenAgents.Repositories

  # A signed-in account that holds no membership anywhere. The shared fixture
  # grants the initial repository, which would defeat every authorization
  # boundary these tests exist to exercise.
  defp sign_in_non_member(conn, key) do
    github_id = System.unique_integer([:positive, :monotonic])

    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: key,
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    Plug.Test.init_test_session(conn, %{"user_id" => user.id})
  end

  defp file_issue(conn, title) do
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues/new")

    view
    |> form("#new-issue-form", issue: %{title: title, body: ""})
    |> render_submit()

    {path, _flash} = assert_redirect(view)
    number = path |> String.split("/") |> List.last() |> String.to_integer()

    Issues.get_issue_by_number!(
      Repositories.get_by_path!("OpenAgentsInc", "openagents.com"),
      number
    )
  end

  describe "anonymous visitors" do
    test "read a public issue and its timeline without any write controls" do
      {:ok, issue} = Issues.create_issue(repository(), %{"title" => "Readable by anyone"})
      {:ok, _} = Issues.create_comment(issue, %{body: "First comment"}, nil)

      {:ok, view, html} =
        live(build_conn(), ~p"/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      assert html =~ "Readable by anyone"
      assert html =~ "First comment"
      refute has_element?(view, "#comment-form")
      assert has_element?(view, "#sign-in-to-comment")
      refute has_element?(view, "#issue-edit-form")
      refute has_element?(view, ~s{button[phx-click="close"]})
      refute has_element?(view, ~s{button[phx-click="toggle_edit"]})
    end

    test "are refused on a private repository" do
      {:ok, _private} =
        Repositories.create_repository(%{
          owner: "SecondOrg",
          name: "secret",
          visibility: "private"
        })

      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(build_conn(), ~p"/SecondOrg/secret/issues")
      end
    end
  end

  describe "signed-in people who are not members" do
    setup %{conn: conn} do
      {:ok, conn: sign_in_non_member(conn, "passerby")}
    end

    test "can file an issue on a public repository and are recorded as its author", %{
      conn: conn
    } do
      issue = file_issue(conn, "Reported from outside")

      assert issue.title == "Reported from outside"
      assert issue.user["login"] == "passerby"
      assert issue.author_user_id != nil
    end

    test "cannot see triage pickers when filing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues/new")

      refute has_element?(view, ~s{select[name="issue[labels]"]})
      refute has_element?(view, ~s{select[name="issue[milestone]"]})
    end

    test "can comment on an open conversation", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{"title" => "Needs a reply"})
      {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      view
      |> form("#comment-form", comment: %{body: "I can reproduce this."})
      |> render_submit()

      [comment] = Issues.list_comments(issue)
      assert has_element?(view, "#comment-#{comment.id}")
      assert comment.body == "I can reproduce this."
      assert comment.author_user_id != nil
    end

    test "cannot post to a conversation locked after the page opened", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{"title" => "Lock this thread"})
      {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues/#{issue.number}")
      {:ok, _locked} = Issues.update_issue(issue, %{"locked" => true})

      html = render_submit(view, "add_comment", %{"comment" => %{"body" => "Too late"}})

      assert html =~ "This conversation is locked"
      assert Issues.list_comments(issue) == []
    end

    test "get no triage controls anywhere on the issue page", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{"title" => "Not yours to close"})
      {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      refute has_element?(view, ~s{button[phx-click="close"]})
      refute has_element?(view, ~s{button[phx-click="toggle_edit"]})
      refute has_element?(view, ~s{[id^="row-state-"]})

      assert Issues.get_issue!(repository(), issue.id).state == "open"
    end

    test "see the issue list with a filing link but no row menus", %{conn: conn} do
      {:ok, _issue} = Issues.create_issue(repository(), %{"title" => "Visible to all"})

      {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues")

      assert html =~ "Visible to all"
      # They can file, because participating is not triaging.
      assert has_element?(view, ~s{a[href="/OpenAgentsInc/openagents.com/issues/new"]})
      refute has_element?(view, ~s{[id^="row-state-"]})
      refute has_element?(view, ~s{[id^="row-assignee-"]})
    end

    test "are refused on private repositories", %{conn: conn} do
      {:ok, _private} =
        Repositories.create_repository(%{
          owner: "SecondOrg",
          name: "inner",
          visibility: "private"
        })

      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(conn, ~p"/SecondOrg/inner/issues")
      end
    end
  end

  describe "the issue's own author" do
    setup %{conn: conn} do
      {:ok, conn: sign_in_non_member(conn, "reporter")}
    end

    test "can edit the title and body of their own issue afterwards", %{conn: conn} do
      issue = file_issue(conn, "Typo in report")

      {:ok, show_view, _html} =
        live(conn, ~p"/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      show_view
      |> element(~s{button[phx-click="toggle_edit"]})
      |> render_click()

      show_view
      |> form("#issue-edit-form", issue: %{title: "Fixed title", body: "Now with steps"})
      |> render_submit()

      updated = Issues.get_issue!(repository(), issue.id)
      assert updated.title == "Fixed title"
      assert updated.body == "Now with steps"
    end

    test "can close their own issue", %{conn: conn} do
      issue = file_issue(conn, "Solved it myself")

      {:ok, show_view, _html} =
        live(conn, ~p"/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      show_view
      |> element(~s{button[phx-click="close"]})
      |> render_click()

      closed = Issues.get_issue!(repository(), issue.id)
      assert closed.state == "closed"
      assert closed.state_reason == "completed"
    end
  end

  defp repository do
    OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
