defmodule OpenAgentsWeb.ProjectIndexLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import OpenAgents.ProjectsFixtures

  alias OpenAgents.Projects

  setup %{conn: conn} do
    user = github_user("project-index")
    {:ok, _membership} = OpenAgents.Repositories.add_member(repository(), user, "owner")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    {:ok, conn: conn, user: user}
  end

  test "mounts with the create form and an empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/projects")

    assert html =~ "Projects"
    assert has_element?(view, "#new-project-form")
    assert has_element?(view, ~s{[role="status"]}, "No projects yet")
  end

  test "a signed-out visitor can read projects without write affordances" do
    {:ok, view, _html} = live(build_conn(), ~p"/OpenAgentsInc/openagents.com/projects")

    assert has_element?(view, "#projects-empty")
    refute has_element?(view, "#new-project-form")
    refute has_element?(view, "button[phx-click=\"delete\"]")
    refute has_element?(view, "button[phx-click=\"set_state\"]")
  end

  test "a signed-out visitor cannot submit a project write event" do
    {:ok, view, _html} = live(build_conn(), ~p"/OpenAgentsInc/openagents.com/projects")

    html = render_submit(view, "save", %{"project" => %{"title" => "Forged"}})

    assert html =~ "Only repository members can create projects."
    refute has_element?(view, "#projects", "Forged")
  end

  test "a private repository is not visible to a signed-out visitor" do
    private =
      repository_fixture(%{owner: "HiddenProjects", name: "projects", visibility: "private"})

    assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
      live(build_conn(), ~p"/#{private.owner}/#{private.name}/projects")
    end
  end

  test "lists projects owned by the URL owner and links to each board", %{conn: conn} do
    project =
      project_fixture(repository(), %{title: "Roadmap", owner: "OpenAgentsInc", state: "open"})

    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/projects")

    refute html =~ "No projects yet"
    assert html =~ "Roadmap"

    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/openagents.com/projects/#{project.number}"]},
             "Roadmap"
           )

    # The row's name is the link to its board. A separate "View" control beside
    # a row that already navigates is one more thing to aim at for the same
    # destination.
    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/openagents.com/projects/#{project.number}"]},
             project.title
           )
  end

  test "the repository board lists projects regardless of their user owner", %{conn: conn} do
    project_fixture(repository(), %{title: "Someone elses", owner: "other-org"})

    {:ok, _view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/projects")

    assert html =~ "Someone elses"
    refute html =~ "No projects yet"
  end

  test "submitting the form creates a project owned by the authenticated member", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/projects")

    html =
      view
      |> form("#new-project-form", project: %{title: "Q3 delivery"})
      |> render_submit()

    assert html =~ "Project created"
    assert html =~ "Q3 delivery"

    assert [project] = Projects.list_projects(repository())
    assert project.title == "Q3 delivery"
    assert project.owner == user.github_login
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
    assert Projects.list_projects(repository()) == []
  end

  test "deleting a project returns the empty state", %{conn: conn} do
    project = project_fixture(repository(), %{title: "Doomed", owner: "OpenAgentsInc"})

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/projects")

    html =
      view
      |> element(~s{button[phx-click="delete"][phx-value-id="#{project.id}"]})
      |> render_click()

    assert html =~ "Project deleted"
    assert has_element?(view, ~s{[role="status"]}, "No projects yet")
    assert Projects.list_projects(repository()) == []
  end

  test "closing a project from its row uses the state GitHub already has", %{conn: conn} do
    # Projects V2 carries `state`, so this changes a real field rather than an
    # invented one. Delete stays a separate control beside the row.
    project =
      project_fixture(repository(), %{title: "Closeable", owner: "OpenAgentsInc", state: "open"})

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/projects")

    view
    |> element(~s{#project-state-#{project.id} button}, "Closed")
    |> render_click()

    assert Projects.get_project!(repository(), project.id).state == "closed"

    assert has_element?(
             view,
             ~s{#project-state-#{project.id} button[aria-current="true"]},
             "Closed"
           )
  end

  defp repository do
    OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
