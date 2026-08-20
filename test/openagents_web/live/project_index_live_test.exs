defmodule OpenAgentsWeb.ProjectIndexLiveTest do
  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import OpenAgents.ProjectsFixtures

  alias OpenAgents.Projects

  setup %{conn: conn} do
    {:ok, conn: log_in_github_user(conn, "project-index")}
  end

  test "mounts with the create form and an empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/projects")

    assert html =~ "Projects"
    assert has_element?(view, "#new-project-form")
    assert has_element?(view, ~s{[role="status"]}, "No projects yet")
  end

  test "lists projects owned by the URL owner and links to each board", %{conn: conn} do
    project = project_fixture(%{title: "Roadmap", owner: "OpenAgentsInc", state: "open"})

    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/projects")

    refute html =~ "No projects yet"
    assert html =~ "Roadmap"

    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/openagents.com/projects/#{project.number}"]},
             "Roadmap"
           )

    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/openagents.com/projects/#{project.number}"]},
             "View"
           )
  end

  test "a project owned by someone else is filtered out", %{conn: conn} do
    project_fixture(%{title: "Someone elses", owner: "other-org"})

    {:ok, _view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/projects")

    refute html =~ "Someone elses"
    assert html =~ "No projects yet"
  end

  test "submitting the form creates a project owned by the URL owner", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/projects")

    html =
      view
      |> form("#new-project-form", project: %{title: "Q3 delivery"})
      |> render_submit()

    assert html =~ "Project created"
    assert html =~ "Q3 delivery"

    assert [project] = Projects.list_projects()
    assert project.title == "Q3 delivery"
    assert project.owner == "OpenAgentsInc"
    assert project.state == "open"
  end

  test "a project with no title re-renders the form with an error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/projects")

    html =
      view
      |> form("#new-project-form", project: %{title: ""})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert has_element?(view, "#new-project-form")
    assert Projects.list_projects() == []
  end

  test "deleting a project returns the empty state", %{conn: conn} do
    project = project_fixture(%{title: "Doomed", owner: "OpenAgentsInc"})

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/projects")

    html =
      view
      |> element(~s{button[phx-click="delete"][phx-value-id="#{project.id}"]})
      |> render_click()

    assert html =~ "Project deleted"
    assert has_element?(view, ~s{[role="status"]}, "No projects yet")
    assert Projects.list_projects() == []
  end
end
