defmodule OpenAgentsWeb.IssueIndexLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import OpenAgents.AccountsFixtures
  import OpenAgents.LabelsFixtures

  alias OpenAgents.Issues

  setup %{conn: conn} do
    {:ok, conn: log_in_github_user(conn, "issue-index")}
  end

  test "mounts with zeroed counts and an empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues")

    assert html =~ "No open issues"
    assert html =~ "Issues will show up here once they are created."
    refute has_element?(view, "#issues")

    # The default filter is `open`, and it is the one marked current.
    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/openagents.com/issues?state=open"][aria-current]}
           )

    refute has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/openagents.com/issues?state=closed"][aria-current]}
           )

    assert has_element?(view, ~s{a[href="/OpenAgentsInc/openagents.com/issues/new"]}, "New issue")
  end

  test "lists open issues with their number, author, labels, and assignees", %{conn: conn} do
    repository_user_fixture("grace-index")
    label_fixture(%{name: "bug", color: "d73a4a"})

    {:ok, issue} =
      Issues.create_issue(%{
        "title" => "Streaming stalls",
        "user" => %{"login" => "ada"},
        "labels" => ["bug"],
        "assignees" => ["grace-index"]
      })

    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues")

    refute html =~ "No open issues"
    assert has_element?(view, "#issues")

    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/openagents.com/issues/#{issue.number}"]},
             "Streaming stalls"
           )

    assert html =~ "##{issue.number}"
    assert html =~ "ada"
    assert html =~ "bug"
    assert has_element?(view, ~s{[title="grace-index"]})
  end

  test "an issue with no author falls back to anonymous", %{conn: conn} do
    {:ok, _} = Issues.create_issue(%{"title" => "Orphaned"})

    {:ok, _view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues")

    assert html =~ "Orphaned"
    assert html =~ "anonymous"
  end

  test "the comment count only renders once an issue has comments", %{conn: conn} do
    {:ok, issue} = Issues.create_issue(%{"title" => "Chatty"})

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues")
    refute has_element?(view, ~s{svg[data-icon="comment"]})

    {:ok, _} =
      Issues.create_comment(%{
        issue_id: issue.id,
        body: "First",
        user: %{"login" => "ada"}
      })

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues")
    assert has_element?(view, ~s{svg[data-icon="comment"]})
  end

  test "patching to the closed filter swaps the stream and the current marker", %{conn: conn} do
    {:ok, _open} = Issues.create_issue(%{"title" => "Open one"})
    {:ok, closed} = Issues.create_issue(%{"title" => "Closed one"})
    {:ok, _} = Issues.update_issue(closed, %{"state" => "closed"})

    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues")
    assert html =~ "Open one"
    refute html =~ "Closed one"

    html =
      view
      |> element(~s{a[href="/OpenAgentsInc/openagents.com/issues?state=closed"]})
      |> render_click()

    assert html =~ "Closed one"
    refute html =~ "Open one"

    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/openagents.com/issues?state=closed"][aria-current]}
           )

    refute has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/openagents.com/issues?state=open"][aria-current]}
           )
  end

  test "the closed filter has its own empty-state wording", %{conn: conn} do
    {:ok, _open} = Issues.create_issue(%{"title" => "Open one"})

    {:ok, _view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues?state=closed")

    assert html =~ "No closed issues"
    refute html =~ "No open issues"
  end

  test "the open and closed counts stay visible on both filters", %{conn: conn} do
    {:ok, _} = Issues.create_issue(%{"title" => "A"})
    {:ok, _} = Issues.create_issue(%{"title" => "B"})
    {:ok, c} = Issues.create_issue(%{"title" => "C"})
    {:ok, _} = Issues.update_issue(c, %{"state" => "closed"})

    for state <- ["open", "closed"] do
      {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues?state=#{state}")

      assert has_element?(
               view,
               ~s{a[href="/OpenAgentsInc/openagents.com/issues?state=open"]},
               "2 Open"
             )

      assert has_element?(
               view,
               ~s{a[href="/OpenAgentsInc/openagents.com/issues?state=closed"]},
               "1 Closed"
             )
    end
  end

  # In Circle the row's parts are selectors. Only two of them survive here:
  # state and assignee are the facts worth changing without opening the issue,
  # and both are GitHub fields. Labels and milestone need option lists longer
  # than a row can explain, so they are edited from the issue page's rail.
  test "closing an issue from its row drops it out of the open filter", %{conn: conn} do
    {:ok, issue} = Issues.create_issue(%{"title" => "Closeable"})
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues")

    assert has_element?(view, ~s{#row-state-#{issue.id}})

    view
    |> element(~s{#row-state-#{issue.id} button}, "Closed as not planned")
    |> render_click()

    closed = Issues.get_issue!(issue.id)
    assert closed.state == "closed"
    assert closed.state_reason == "not_planned"

    # The list is filtered to open issues, so a closed one has to leave it --
    # a row that stays visible after being closed is worse than a reload.
    refute has_element?(view, ~s{#row-state-#{issue.id}})

    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/openagents.com/issues?state=closed"]},
             "1 Closed"
           )
  end

  test "assigning from a row keeps the row and updates the face", %{conn: conn} do
    repository_user_fixture("hopper-index")
    {:ok, issue} = Issues.create_issue(%{"title" => "Assignable"})
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues")

    view
    |> element(~s{#row-assignee-#{issue.id} button}, "hopper-index")
    |> render_click()

    assert Issues.get_issue!(issue.id).assignees |> Enum.map(& &1["login"]) == ["hopper-index"]
    assert has_element?(view, ~s{#row-assignee-#{issue.id}})
    assert has_element?(view, ~s{[title="hopper-index"]})
  end

  test "the row's controls sit outside the link to the issue", %{conn: conn} do
    # A state-changing control inside a link target is how people mis-click.
    {:ok, issue} = Issues.create_issue(%{"title" => "Separate hit areas"})
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues")

    title_link =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("a.issue-row__title")
      |> LazyHTML.to_tree()

    assert title_link != []
    refute inspect(title_link) =~ "row-state-#{issue.id}"
    refute inspect(title_link) =~ "row-assignee-#{issue.id}"
  end

  # Reading a public repository's issues is a public activity now, the same
  # way reading its code is: no redirect, no controls, and an invitation to
  # sign in rather than a wall.
  test "an anonymous visitor reads a public repository's issue list" do
    {:ok, _issue} = Issues.create_issue(%{"title" => "Public spectable"})

    {:ok, view, html} = live(build_conn(), ~p"/OpenAgentsInc/openagents.com/issues")

    assert html =~ "Public spectable"
    refute has_element?(view, "#issues-empty")
    # No triage controls, no filing link: the toolbar actions need authority.
    refute has_element?(view, ~s{a[href="/OpenAgentsInc/openagents.com/issues/new"]})
    refute has_element?(view, ~s{[id^="row-state-"]})
    refute has_element?(view, ~s{[id^="row-assignee-"]})
  end

  test "an anonymous visitor cannot open a private repository's issues" do
    assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
      live(build_conn(), ~p"/SecondOrg/hidden-repo/issues")
    end
  end
end
