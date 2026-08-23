defmodule OpenAgentsWeb.ProjectShowLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import OpenAgents.LabelsFixtures
  import OpenAgents.ProjectItemsFixtures
  import OpenAgents.ProjectsFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Projects

  setup %{conn: conn} do
    {:ok, conn: log_in_repository_user(conn, "project-show", repository())}
  end

  defp project!, do: project_fixture(repository(), %{title: "Roadmap", owner: "OpenAgentsInc"})

  defp path(project), do: ~p"/OpenAgentsInc/openagents.com/projects/#{project.number}"

  test "mounts and renders every board column plus the add form", %{conn: conn} do
    project = project!()

    {:ok, view, html} = live(conn, path(project))

    assert html =~ "Roadmap"
    assert html =~ "To Do"
    assert html =~ "In Progress"
    assert html =~ "Done"
    assert has_element?(view, "#new-project-item-form")

    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/openagents.com/projects"]},
             "Back to projects"
           )
  end

  test "a signed-out visitor can read a project board without the add form" do
    project = project!()

    {:ok, view, _html} = live(build_conn(), path(project))

    assert has_element?(view, "#project-board-title")
    refute has_element?(view, "#new-project-item-form")
  end

  test "a signed-out visitor cannot submit an add-item event" do
    project = project!()
    {:ok, issue} = Issues.create_issue(repository(), %{"title" => "Hidden forged item"})

    {:ok, view, _html} = live(build_conn(), path(project))

    html =
      render_submit(view, "add_item", %{
        "item" => %{"issue_number" => to_string(issue.number), "status" => "Done"}
      })

    assert html =~ "Only repository members can add project items."
    refute has_element?(view, ~s{a[href="/OpenAgentsInc/openagents.com/issues/#{issue.number}"]})
  end

  test "a private repository is not visible to a signed-out visitor" do
    private =
      repository_fixture(%{owner: "HiddenBoard", name: "projects", visibility: "private"})

    assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
      live(build_conn(), ~p"/#{private.owner}/#{private.name}/projects/1")
    end
  end

  test "an empty board renders the columns with no cards", %{conn: conn} do
    project = project!()

    {:ok, view, _html} = live(conn, path(project))

    refute has_element?(view, ~s{a[href^="/OpenAgentsInc/openagents.com/issues/"]})
    # With no issues in the repo the issue select carries only its prompt.
    refute has_element?(view, ~s{#item_issue_number option:not([value=""])})
  end

  test "the issue select offers every issue, open or closed", %{conn: conn} do
    project = project!()
    {:ok, open} = Issues.create_issue(repository(), %{"title" => "Still open"})
    {:ok, closed} = Issues.create_issue(repository(), %{"title" => "All done"})
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
    label_fixture(repository(), %{name: "bug", color: "d73a4a"})

    {:ok, issue} =
      Issues.create_issue(repository(), %{"title" => "Fix the parser", "labels" => ["bug"]})

    {:ok, _item} =
      Projects.create_project_item(
        %{"issue_number" => issue.number, "values" => %{"Status" => "In Progress"}},
        project
      )

    {:ok, view, html} = live(conn, path(project))

    assert html =~ "Fix the parser"
    assert html =~ "bug"

    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/openagents.com/issues/#{issue.number}"]},
             "Fix the parser"
           )
  end

  test "an item with no recorded status falls back to To Do", %{conn: conn} do
    project = project!()
    {:ok, issue} = Issues.create_issue(repository(), %{"title" => "Unsorted"})

    {:ok, _item} =
      Projects.create_project_item(
        %{"issue_number" => issue.number, "values" => %{}},
        project
      )

    {:ok, _view, html} = live(conn, path(project))

    assert html =~ "Unsorted"
  end

  test "submitting the form adds the issue to the board", %{conn: conn} do
    project = project!()
    {:ok, issue} = Issues.create_issue(repository(), %{"title" => "Ship the runbook"})

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
             ~s{a[href="/OpenAgentsInc/openagents.com/issues/#{issue.number}"]},
             "Ship the runbook"
           )

    assert [item] = Projects.list_project_items(project)
    assert item.issue_id == issue.id
    assert item.values == %{"Status" => "Done"}
  end

  test "a fixture-built item lands in the column named by its Status value", %{conn: conn} do
    project = project!()
    {:ok, issue} = Issues.create_issue(repository(), %{"title" => "Fixture-placed"})

    item =
      project_item_fixture(repository(), %{
        project_id: project.id,
        issue_id: issue.id,
        values: %{"Status" => "Done"}
      })

    assert item.project_id == project.id

    {:ok, view, _html} = live(conn, path(project))

    # Cards are grouped by column; the "Done" column is the third section.
    assert has_element?(
             view,
             ~s{section:nth-of-type(3) a[href="/OpenAgentsInc/openagents.com/issues/#{issue.number}"]},
             "Fixture-placed"
           )

    refute has_element?(
             view,
             ~s{section:nth-of-type(1) a[href="/OpenAgentsInc/openagents.com/issues/#{issue.number}"]}
           )
  end

  test "a cross-repository card names and links to its source repository", %{conn: conn} do
    project = project!()

    source =
      repository_fixture(%{owner: "SourceOrg", name: "source-board", visibility: "public"})

    {:ok, issue} = Issues.create_issue(source, %{"title" => "Cross-repository card"})

    {:ok, _item} =
      Projects.create_project_item(
        %{
          "issue_number" => issue.number,
          "issue_repository_id" => source.id,
          "values" => %{"Status" => "To Do"}
        },
        project
      )

    {:ok, view, html} = live(conn, path(project))

    assert html =~ "SourceOrg/source-board##{issue.number}"

    assert has_element?(
             view,
             ~s{a[href="/SourceOrg/source-board/issues/#{issue.number}"]},
             "Cross-repository card"
           )
  end

  test "a card whose source repository is unreadable never renders", %{conn: conn} do
    project = project!()

    source =
      repository_fixture(%{owner: "HiddenOrg", name: "hidden-board", visibility: "private"})

    {:ok, issue} = Issues.create_issue(source, %{"title" => "Confidential card"})

    {:ok, _item} =
      Projects.create_project_item(
        %{
          "issue_number" => issue.number,
          "issue_repository_id" => source.id,
          "values" => %{"Status" => "To Do"}
        },
        project
      )

    {:ok, view, html} = live(conn, path(project))

    refute html =~ "Confidential card"
    refute html =~ "hidden-board"

    refute has_element?(
             view,
             ~s{a[href="/HiddenOrg/hidden-board/issues/#{issue.number}"]}
           )
  end

  test "a missing project number raises rather than rendering an empty board", %{conn: conn} do
    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/OpenAgentsInc/openagents.com/projects/9999")
    end
  end

  describe "description" do
    test "renders the description as Markdown, with an empty state when there is none", %{
      conn: conn
    } do
      project = project!()

      {:ok, view, html} = live(conn, path(project))
      assert html =~ "No description yet"
      assert has_element?(view, "#project-description-empty")

      {:ok, _updated} =
        Projects.update_project(project, %{"description" => "## Why\n\nProvider order."})

      html = render(view)
      assert html =~ "<h2>Why</h2>"
      refute html =~ "No description yet"
    end

    test "a member edits the description and the change lands in the activity feed", %{
      conn: conn
    } do
      project = project!()

      {:ok, view, _html} = live(conn, path(project))

      view |> element("#edit-description") |> render_click()

      html =
        view
        |> form("#project-description-form", project: %{description: "Operating notes."})
        |> render_submit()

      assert html =~ "Operating notes."
      assert html =~ "Updated the description."

      assert Projects.get_project_by_number!(repository(), project.number).description ==
               "Operating notes."
    end
  end

  describe "discussion" do
    test "an empty project shows the notes empty state", %{conn: conn} do
      project = project!()

      {:ok, view, html} = live(conn, path(project))

      assert html =~ "Discussion and activity"
      assert has_element?(view, "#project-notes-empty")
    end

    test "a member adds a note and can delete their own", %{conn: conn} do
      project = project!()

      {:ok, view, _html} = live(conn, path(project))

      html =
        view
        |> form("#project-note-form", note: %{body: "Lane 3 is paused."})
        |> render_submit()

      assert html =~ "Lane 3 is paused."
      assert [note] = elem(Projects.list_project_notes_page(project), 0)
      assert has_element?(view, "#project-note-#{note.id}")

      html = view |> element("#project-note-#{note.id} button", "Delete") |> render_click()

      refute html =~ "Lane 3 is paused."
      assert Projects.count_project_notes(project) == 0
    end

    test "pagination appears once the notes outrun one page", %{conn: conn} do
      project = project!()
      per_page = Projects.notes_per_page()

      for index <- 1..(per_page + 1) do
        {:ok, _note} = Projects.create_project_note(project, %{"body" => "note #{index}"})
      end

      {:ok, view, _html} = live(conn, path(project))

      assert has_element?(view, "#project-notes-pagination")
      assert render(view) =~ "Page 1 of 2"

      html = view |> element("#project-notes-pagination button", "Older") |> render_click()

      assert html =~ "Page 2 of 2"
      assert html =~ "note 1"
    end

    test "a note written remotely reaches an open board without a reload", %{conn: conn} do
      project = project!()

      {:ok, view, _html} = live(conn, path(project))

      {:ok, _note} =
        Projects.create_project_note(project, %{"body" => "Decided by the CLI."})

      {:ok, _updated} = Projects.update_project(project, %{"title" => "Renamed remotely"})

      html = render(view)
      assert html =~ "Decided by the CLI."
      assert html =~ "Renamed remotely"
    end
  end

  describe "a reader without write access" do
    setup %{conn: conn} do
      {:ok, conn: log_in_github_user(conn, "project-show-reader")}
    end

    test "reads the board and the notes but writes nothing", %{conn: conn} do
      project = project!()
      {:ok, _note} = Projects.create_project_note(project, %{"body" => "Context for readers."})

      {:ok, view, html} = live(conn, path(project))

      assert html =~ "Context for readers."
      assert has_element?(view, "#project-notes-unauthorized")
      refute has_element?(view, "#project-note-form")
      refute has_element?(view, "#new-project-item-form")
      refute has_element?(view, "#edit-description")
    end
  end

  defp repository do
    OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
