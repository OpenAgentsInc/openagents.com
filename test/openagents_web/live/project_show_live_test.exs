defmodule OpenAgentsWeb.ProjectShowLiveTest do
  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import OpenAgents.LabelsFixtures
  import OpenAgents.ProjectItemsFixtures
  import OpenAgents.ProjectsFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Projects

  setup %{conn: conn} do
    {:ok, conn: log_in_github_user(conn, "project-show")}
  end

  defp project!, do: project_fixture(%{title: "Roadmap", owner: "OpenAgentsInc"})

  defp path(project), do: ~p"/OpenAgentsInc/sarah/projects/#{project.number}"

  test "mounts and renders every board column plus the add form", %{conn: conn} do
    project = project!()

    {:ok, view, html} = live(conn, path(project))

    assert html =~ "Roadmap"
    assert html =~ "To Do"
    assert html =~ "In Progress"
    assert html =~ "Done"
    assert has_element?(view, "#new-project-item-form")
    assert has_element?(view, ~s{a[href="/OpenAgentsInc/sarah/projects"]}, "Back to projects")
  end

  test "an empty board renders the columns with no cards", %{conn: conn} do
    project = project!()

    {:ok, view, _html} = live(conn, path(project))

    refute has_element?(view, ~s{a[href^="/OpenAgentsInc/sarah/issues/"]})
    # With no issues in the repo the issue select carries only its prompt.
    refute has_element?(view, ~s{#item_issue_number option:not([value=""])})
  end

  test "the issue select offers every issue, open or closed", %{conn: conn} do
    project = project!()
    {:ok, open} = Issues.create_issue(%{"title" => "Still open"})
    {:ok, closed} = Issues.create_issue(%{"title" => "All done"})
    {:ok, _} = Issues.update_issue(closed, %{"state" => "closed"})

    {:ok, view, _html} = live(conn, path(project))

    assert has_element?(
             view,
             ~s{#item_issue_number option[value="#{open.number}"]},
             "##{open.number} Still open"
           )

    assert has_element?(
             view,
             ~s{#item_issue_number option[value="#{closed.number}"]},
             "##{closed.number} All done"
           )

    for status <- ["To Do", "In Progress", "Done"] do
      assert has_element?(view, ~s{#item_status option[value="#{status}"]}, status)
    end
  end

  test "an existing item renders as a card in its status column", %{conn: conn} do
    project = project!()
    label_fixture(%{name: "bug", color: "d73a4a"})
    {:ok, issue} = Issues.create_issue(%{"title" => "Fix the parser", "labels" => ["bug"]})

    {:ok, _item} =
      Projects.create_project_item(
        %{"issue_number" => issue.number, "values" => %{"Status" => "In Progress"}},
        project.id
      )

    {:ok, view, html} = live(conn, path(project))

    assert html =~ "Fix the parser"
    assert html =~ "bug"

    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/sarah/issues/#{issue.number}"]},
             "Fix the parser"
           )
  end

  test "an item with no recorded status falls back to To Do", %{conn: conn} do
    project = project!()
    {:ok, issue} = Issues.create_issue(%{"title" => "Unsorted"})

    {:ok, _item} =
      Projects.create_project_item(
        %{"issue_number" => issue.number, "values" => %{}},
        project.id
      )

    {:ok, _view, html} = live(conn, path(project))

    assert html =~ "Unsorted"
  end

  test "submitting the form adds the issue to the board", %{conn: conn} do
    project = project!()
    {:ok, issue} = Issues.create_issue(%{"title" => "Ship the runbook"})

    {:ok, view, html} = live(conn, path(project))
    refute html =~ "Ship the runbook</a>"

    html =
      view
      |> form("#new-project-item-form",
        item: %{issue_number: to_string(issue.number), status: "Done"}
      )
      |> render_submit()

    assert html =~ "Issue added to project"

    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/sarah/issues/#{issue.number}"]},
             "Ship the runbook"
           )

    assert [item] = Projects.list_project_items(project.id)
    assert item.issue_id == issue.id
    assert item.values == %{"Status" => "Done"}
  end

  test "a fixture-built item lands in the column named by its Status value", %{conn: conn} do
    project = project!()
    {:ok, issue} = Issues.create_issue(%{"title" => "Fixture-placed"})

    item =
      project_item_fixture(%{
        project_id: project.id,
        issue_id: issue.id,
        values: %{"Status" => "Done"}
      })

    assert item.project_id == project.id

    {:ok, view, _html} = live(conn, path(project))

    # Cards are grouped by column; the "Done" column is the third section.
    assert has_element?(
             view,
             ~s{section:nth-of-type(3) a[href="/OpenAgentsInc/sarah/issues/#{issue.number}"]},
             "Fixture-placed"
           )

    refute has_element?(
             view,
             ~s{section:nth-of-type(1) a[href="/OpenAgentsInc/sarah/issues/#{issue.number}"]}
           )
  end

  test "a missing project number raises rather than rendering an empty board", %{conn: conn} do
    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/OpenAgentsInc/sarah/projects/9999")
    end
  end
end
