defmodule OpenAgentsWeb.MilestoneIndexLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import OpenAgents.MilestonesFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Milestones

  setup %{conn: conn} do
    {:ok, conn: log_in_repository_user(conn, "milestone-index", repository())}
  end

  test "mounts with the create form and an empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/milestones")

    assert html =~ "Milestones"
    assert has_element?(view, "#new-milestone-form")
    assert has_element?(view, ~s{[role="status"]}, "No milestones yet")
  end

  test "lists seeded milestones with their state and due date", %{conn: conn} do
    milestone_fixture(repository(), %{
      title: "v1.0",
      state: "open",
      due_on: "2026-12-31",
      description: "Ship"
    })

    {:ok, _view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/milestones")

    refute html =~ "No milestones yet"
    assert html =~ "v1.0"
    assert html =~ "Ship"
    assert html =~ "Due 2026-12-31"
  end

  test "the progress meter reports the closed-to-total ratio", %{conn: conn} do
    milestone = milestone_fixture(repository(), %{title: "Beta", state: "open", due_on: nil})

    {:ok, open_issue} = Issues.create_issue(repository(), %{"title" => "Still open"})
    {:ok, _} = Issues.set_milestone(open_issue, milestone.number)

    {:ok, done_issue} = Issues.create_issue(repository(), %{"title" => "Finished"})
    {:ok, done_issue} = Issues.set_milestone(done_issue, milestone.number)
    {:ok, _} = Issues.update_issue(done_issue, %{"state" => "closed"})

    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/milestones")

    assert has_element?(
             view,
             ~s{[role="progressbar"][aria-label="Beta progress"][aria-valuenow="50"]}
           )

    assert html =~ "1 open"
    assert html =~ "1 closed"
    assert html =~ "2 total"
    assert html =~ "50%"
  end

  test "a milestone with no issues reports zero progress", %{conn: conn} do
    milestone_fixture(repository(), %{title: "Empty", due_on: nil})

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/milestones")

    assert has_element?(
             view,
             ~s{[role="progressbar"][aria-label="Empty progress"][aria-valuenow="0"]}
           )
  end

  test "submitting the form creates a milestone", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/milestones")

    html =
      view
      |> form("#new-milestone-form",
        milestone: %{title: "v2.0", due_on: "2027-01-01", description: "Next"}
      )
      |> render_submit()

    assert html =~ "Milestone created"
    assert html =~ "v2.0"

    assert [%Milestones.Milestone{title: "v2.0", number: 1}] =
             Milestones.list_milestones(repository())
  end

  test "a milestone with no title re-renders the form with an error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/milestones")

    html =
      view
      |> form("#new-milestone-form", milestone: %{title: "", due_on: "", description: ""})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert Milestones.list_milestones(repository()) == []
  end

  test "closing a milestone flips its state and hides the close button", %{conn: conn} do
    milestone = milestone_fixture(repository(), %{title: "Closeable", state: "open", due_on: nil})

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/milestones")
    assert has_element?(view, ~s{button[phx-click="close"][phx-value-id="#{milestone.id}"]})

    html =
      view
      |> element(~s{button[phx-click="close"][phx-value-id="#{milestone.id}"]})
      |> render_click()

    assert html =~ "Milestone closed"
    refute has_element?(view, ~s{button[phx-click="close"][phx-value-id="#{milestone.id}"]})
    assert Milestones.get_milestone!(repository(), milestone.id).state == "closed"
  end

  test "deleting a milestone returns the empty state", %{conn: conn} do
    milestone = milestone_fixture(repository(), %{title: "Deletable", due_on: nil})

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/milestones")

    html =
      view
      |> element(~s{button[phx-click="delete"][phx-value-id="#{milestone.id}"]})
      |> render_click()

    assert html =~ "Milestone deleted"
    assert has_element?(view, ~s{[role="status"]}, "No milestones yet")
    assert Milestones.list_milestones(repository()) == []
  end

  defp repository do
    OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
