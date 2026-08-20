defmodule OpenAgentsWeb.IssueIndexLiveTest do
  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import OpenAgents.LabelsFixtures

  alias OpenAgents.Issues

  setup %{conn: conn} do
    {:ok, conn: log_in_github_user(conn, "issue-index")}
  end

  test "mounts with zeroed counts and an empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/sarah/issues")

    assert html =~ "No open issues"
    assert html =~ "Issues will show up here once they are created."
    refute has_element?(view, "#issues")

    # The default filter is `open`, and it is the one marked current.
    assert has_element?(view, ~s{a[href="/OpenAgentsInc/sarah/issues?state=open"][aria-current]})

    refute has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/sarah/issues?state=closed"][aria-current]}
           )

    assert has_element?(view, ~s{a[href="/OpenAgentsInc/sarah/issues/new"]}, "New issue")
  end

  test "lists open issues with their number, author, labels, and assignees", %{conn: conn} do
    label_fixture(%{name: "bug", color: "d73a4a"})

    {:ok, issue} =
      Issues.create_issue(%{
        "title" => "Streaming stalls",
        "user" => %{"login" => "ada"},
        "labels" => ["bug"],
        "assignees" => ["grace"]
      })

    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/sarah/issues")

    refute html =~ "No open issues"
    assert has_element?(view, "#issues")

    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/sarah/issues/#{issue.number}"]},
             "Streaming stalls"
           )

    assert html =~ "##{issue.number}"
    assert html =~ "ada"
    assert html =~ "bug"
    assert has_element?(view, ~s{[title="grace"]})
  end

  test "an issue with no author falls back to anonymous", %{conn: conn} do
    {:ok, _} = Issues.create_issue(%{"title" => "Orphaned"})

    {:ok, _view, html} = live(conn, ~p"/OpenAgentsInc/sarah/issues")

    assert html =~ "Orphaned"
    assert html =~ "anonymous"
  end

  test "the comment count only renders once an issue has comments", %{conn: conn} do
    {:ok, issue} = Issues.create_issue(%{"title" => "Chatty"})

    {:ok, _view, html} = live(conn, ~p"/OpenAgentsInc/sarah/issues")
    refute html =~ "hero-chat-bubble-left"

    {:ok, _} =
      Issues.create_comment(%{
        issue_id: issue.id,
        body: "First",
        user: %{"login" => "ada"}
      })

    {:ok, _view, html} = live(conn, ~p"/OpenAgentsInc/sarah/issues")
    assert html =~ "hero-chat-bubble-left"
  end

  test "patching to the closed filter swaps the stream and the current marker", %{conn: conn} do
    {:ok, _open} = Issues.create_issue(%{"title" => "Open one"})
    {:ok, closed} = Issues.create_issue(%{"title" => "Closed one"})
    {:ok, _} = Issues.update_issue(closed, %{"state" => "closed"})

    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/sarah/issues")
    assert html =~ "Open one"
    refute html =~ "Closed one"

    html =
      view
      |> element(~s{a[href="/OpenAgentsInc/sarah/issues?state=closed"]})
      |> render_click()

    assert html =~ "Closed one"
    refute html =~ "Open one"

    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/sarah/issues?state=closed"][aria-current]}
           )

    refute has_element?(view, ~s{a[href="/OpenAgentsInc/sarah/issues?state=open"][aria-current]})
  end

  test "the closed filter has its own empty-state wording", %{conn: conn} do
    {:ok, _open} = Issues.create_issue(%{"title" => "Open one"})

    {:ok, _view, html} = live(conn, ~p"/OpenAgentsInc/sarah/issues?state=closed")

    assert html =~ "No closed issues"
    refute html =~ "No open issues"
  end

  test "the open and closed counts stay visible on both filters", %{conn: conn} do
    {:ok, _} = Issues.create_issue(%{"title" => "A"})
    {:ok, _} = Issues.create_issue(%{"title" => "B"})
    {:ok, c} = Issues.create_issue(%{"title" => "C"})
    {:ok, _} = Issues.update_issue(c, %{"state" => "closed"})

    for state <- ["open", "closed"] do
      {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/sarah/issues?state=#{state}")

      assert has_element?(
               view,
               ~s{a[href="/OpenAgentsInc/sarah/issues?state=open"]},
               "2 Open"
             )

      assert has_element?(
               view,
               ~s{a[href="/OpenAgentsInc/sarah/issues?state=closed"]},
               "1 Closed"
             )
    end
  end

  test "an anonymous visitor is redirected away from the issue list" do
    assert {:error, {:redirect, %{to: to}}} = live(build_conn(), ~p"/OpenAgentsInc/sarah/issues")
    refute to == "/OpenAgentsInc/sarah/issues"
  end
end
