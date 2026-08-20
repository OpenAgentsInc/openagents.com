defmodule OpenAgentsWeb.IssueShowLiveTest do
  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import OpenAgents.LabelsFixtures
  import OpenAgents.MilestonesFixtures

  alias OpenAgents.Issues

  setup %{conn: conn} do
    {:ok, conn: log_in_github_user(conn, "issue-show")}
  end

  defp issue!(attrs) do
    {:ok, issue} = Issues.create_issue(attrs)
    issue
  end

  defp path(issue), do: ~p"/OpenAgentsInc/sarah/issues/#{issue.number}"

  test "mounts and renders the title, number, state, and body", %{conn: conn} do
    issue =
      issue!(%{
        "title" => "Streaming stalls",
        "body" => "It hangs",
        "user" => %{"login" => "ada"}
      })

    {:ok, view, html} = live(conn, path(issue))

    assert html =~ "Streaming stalls"
    assert html =~ "##{issue.number}"
    assert html =~ "It hangs"
    assert html =~ "ada"
    assert has_element?(view, ~s{button[phx-click="close"]}, "Close issue")
    refute has_element?(view, ~s{button[phx-click="reopen"]})
  end

  test "an issue with no body says so rather than rendering blank", %{conn: conn} do
    issue = issue!(%{"title" => "Bare"})

    {:ok, _view, html} = live(conn, path(issue))

    assert html =~ "No description provided."
    assert html =~ "anonymous"
  end

  test "the sidebar only renders sections the issue actually has", %{conn: conn} do
    bare = issue!(%{"title" => "Bare"})
    {:ok, _view, html} = live(conn, path(bare))

    refute html =~ "Labels"
    refute html =~ "Assignees"
    refute html =~ "Milestone"

    label_fixture(%{name: "bug", color: "d73a4a"})
    milestone = milestone_fixture(%{title: "v1.0", due_on: nil})

    rich = issue!(%{"title" => "Rich", "labels" => ["bug"], "assignees" => ["grace"]})
    {:ok, rich} = Issues.set_milestone(rich, milestone.number)

    {:ok, view, html} = live(conn, path(rich))

    assert html =~ "Labels"
    assert html =~ "bug"
    assert html =~ "Assignees"
    assert has_element?(view, ~s{[title="grace"]})
    assert has_element?(view, ~s{a[href="/OpenAgentsInc/sarah/milestones"]}, "v1.0")
  end

  test "a missing issue number raises rather than rendering an empty page", %{conn: conn} do
    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/OpenAgentsInc/sarah/issues/9999")
    end
  end

  test "closing then reopening an issue swaps the action buttons", %{conn: conn} do
    issue = issue!(%{"title" => "Toggle me"})
    {:ok, view, _html} = live(conn, path(issue))

    html = view |> element(~s{button[phx-click="close"]}) |> render_click()

    assert html =~ "Issue closed"
    assert has_element?(view, ~s{button[phx-click="reopen"]}, "Reopen issue")
    refute has_element?(view, ~s{button[phx-click="close"]})

    closed = Issues.get_issue!(issue.id)
    assert closed.state == "closed"
    assert closed.state_reason == "completed"
    assert closed.closed_at

    html = view |> element(~s{button[phx-click="reopen"]}) |> render_click()

    assert html =~ "Issue reopened"
    assert has_element?(view, ~s{button[phx-click="close"]}, "Close issue")

    reopened = Issues.get_issue!(issue.id)
    assert reopened.state == "open"
    assert reopened.closed_at == nil
  end

  test "the edit toggle swaps the header for the edit form and back", %{conn: conn} do
    issue = issue!(%{"title" => "Editable", "body" => "Before"})
    {:ok, view, _html} = live(conn, path(issue))

    refute has_element?(view, "#issue-edit-form")

    view |> element(~s{button[phx-click="toggle_edit"]}) |> render_click()
    assert has_element?(view, "#issue-edit-form")
    refute has_element?(view, ~s{button[phx-click="close"]})

    view |> element(~s{#issue-edit-form button[phx-click="toggle_edit"]}) |> render_click()
    refute has_element?(view, "#issue-edit-form")
    assert has_element?(view, ~s{button[phx-click="close"]})
  end

  test "saving the edit form updates the issue and leaves edit mode", %{conn: conn} do
    issue = issue!(%{"title" => "Editable", "body" => "Before"})
    {:ok, view, _html} = live(conn, path(issue))

    view |> element(~s{button[phx-click="toggle_edit"]}) |> render_click()

    html =
      view
      |> form("#issue-edit-form", issue: %{title: "Edited", body: "After"})
      |> render_submit()

    assert html =~ "Issue updated"
    assert html =~ "Edited"
    assert html =~ "After"
    refute has_element?(view, "#issue-edit-form")

    updated = Issues.get_issue!(issue.id)
    assert updated.title == "Edited"
    assert updated.body == "After"
  end

  test "clearing the title in the edit form keeps the form and shows the error", %{conn: conn} do
    issue = issue!(%{"title" => "Editable"})
    {:ok, view, _html} = live(conn, path(issue))

    view |> element(~s{button[phx-click="toggle_edit"]}) |> render_click()

    html =
      view
      |> form("#issue-edit-form", issue: %{title: "", body: "still here"})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert has_element?(view, "#issue-edit-form")
    assert Issues.get_issue!(issue.id).title == "Editable"
  end

  test "adding a comment appends it to the thread and bumps the count", %{conn: conn} do
    issue = issue!(%{"title" => "Discuss"})
    {:ok, view, html} = live(conn, path(issue))

    assert has_element?(view, "#comment-form")
    refute html =~ "Looks good to me"

    html =
      view
      |> form("#comment-form", comment: %{body: "Looks good to me"})
      |> render_submit()

    assert html =~ "Comment added"
    assert html =~ "Looks good to me"
    assert html =~ "anonymous"

    assert [comment] = Issues.list_comments(issue.id)
    assert comment.body == "Looks good to me"
    assert Issues.get_issue!(issue.id).comments == 1
  end

  test "an empty comment body is rejected and nothing is stored", %{conn: conn} do
    issue = issue!(%{"title" => "Discuss"})
    {:ok, view, _html} = live(conn, path(issue))

    html =
      view
      |> form("#comment-form", comment: %{body: ""})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert Issues.list_comments(issue.id) == []
    assert Issues.get_issue!(issue.id).comments == 0
  end

  test "existing comments render with their author on mount", %{conn: conn} do
    issue = issue!(%{"title" => "Discuss"})

    {:ok, _} =
      Issues.create_comment(%{
        issue_id: issue.id,
        body: "Earlier note",
        user: %{"login" => "ada"}
      })

    {:ok, _view, html} = live(conn, path(issue))

    assert html =~ "Earlier note"
    assert html =~ "ada"
  end

  test "an anonymous visitor is redirected away from an issue page" do
    issue = issue!(%{"title" => "Private"})

    assert {:error, {:redirect, %{to: to}}} = live(build_conn(), path(issue))
    refute to == "/OpenAgentsInc/sarah/issues/#{issue.number}"
  end
end
