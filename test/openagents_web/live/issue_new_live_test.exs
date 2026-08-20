defmodule OpenAgentsWeb.IssueNewLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import OpenAgents.LabelsFixtures
  import OpenAgents.MilestonesFixtures

  alias OpenAgents.Issues

  setup %{conn: conn} do
    {:ok, conn: log_in_github_user(conn, "issue-new")}
  end

  test "mounts with an empty form and a cancel link back to the list", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues/new")

    assert html =~ "New issue"
    assert has_element?(view, "#new-issue-form")
    assert has_element?(view, "#issue_title")
    assert has_element?(view, "#issue_body")
    assert has_element?(view, ~s{a[href="/OpenAgentsInc/openagents.com/issues"]}, "Cancel")
  end

  test "the milestone and label selects offer the seeded records", %{conn: conn} do
    milestone = milestone_fixture(%{title: "v1.0", due_on: nil})
    label_fixture(%{name: "bug", color: "d73a4a"})

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues/new")

    assert has_element?(view, ~s{#issue_milestone option[value="#{milestone.number}"]}, "v1.0")
    assert has_element?(view, ~s{#issue_labels option[value="bug"]}, "bug")
    assert has_element?(view, ~s{#issue_milestone option[value=""]}, "Select a milestone")
  end

  test "with no milestones or labels the selects render only the prompt", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues/new")

    assert has_element?(view, "#issue_milestone")
    refute has_element?(view, ~s{#issue_labels option})
  end

  test "submitting a title creates the issue and navigates to it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues/new")

    result =
      view
      |> form("#new-issue-form", issue: %{title: "Add a runbook", body: "Please"})
      |> render_submit()

    assert [issue] = Issues.list_issues()
    assert issue.title == "Add a runbook"
    assert issue.body == "Please"

    {:ok, _show, html} =
      follow_redirect(result, conn, ~p"/OpenAgentsInc/openagents.com/issues/#{issue.number}")

    assert html =~ "Issue created"
    assert html =~ "Add a runbook"
  end

  test "a submitted label and milestone are applied to the new issue", %{conn: conn} do
    milestone = milestone_fixture(%{title: "v1.0", due_on: nil})
    label_fixture(%{name: "bug", color: "d73a4a"})

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues/new")

    assert {:error, {:live_redirect, _}} =
             view
             |> form("#new-issue-form",
               issue: %{
                 title: "Tagged",
                 body: "",
                 milestone: to_string(milestone.number),
                 labels: ["bug"]
               }
             )
             |> render_submit()

    assert [issue] = Issues.list_issues()
    assert [%{"name" => "bug", "color" => "d73a4a"}] = issue.labels
    assert issue.milestone["title"] == "v1.0"
    assert issue.milestone["number"] == milestone.number
  end

  test "an empty label and milestone selection leaves the issue bare", %{conn: conn} do
    label_fixture(%{name: "bug", color: "d73a4a"})

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues/new")

    assert {:error, {:live_redirect, _}} =
             view
             |> form("#new-issue-form",
               issue: %{title: "Bare", body: "", milestone: "", labels: []}
             )
             |> render_submit()

    assert [issue] = Issues.list_issues()
    assert issue.labels == []
    assert issue.milestone == nil
  end

  test "a blank title re-renders the form with an error and creates nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues/new")

    html =
      view
      |> form("#new-issue-form", issue: %{title: "", body: "no title"})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert has_element?(view, "#new-issue-form")
    assert Issues.list_issues(state: "all") == []
  end
end
