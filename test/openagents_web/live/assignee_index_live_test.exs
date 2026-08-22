defmodule OpenAgentsWeb.AssigneeIndexLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Issues
  import OpenAgents.AccountsFixtures

  setup %{conn: conn} do
    {:ok, conn: log_in_repository_user(conn, "assignee-index", repository())}
  end

  test "mounts with an honest empty state when no issue has an assignee", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/assignees")

    assert html =~ "Assignees"
    assert has_element?(view, ~s{[role="status"]}, "No assignees have been assigned")
    refute has_element?(view, "#assignees")
  end

  test "tallies assignees across open and closed issues, most-assigned first", %{conn: conn} do
    for login <- ["ada-assignee", "grace-assignee"] do
      user = repository_user_fixture(login)
      {:ok, _membership} = OpenAgents.Repositories.add_member(repository(), user, "contributor")
    end

    {:ok, _first} =
      Issues.create_issue(repository(), %{
        "title" => "First",
        "assignees" => ["ada-assignee", "grace-assignee"]
      })

    {:ok, _second} =
      Issues.create_issue(repository(), %{"title" => "Second", "assignees" => ["ada-assignee"]})

    {:ok, third} =
      Issues.create_issue(repository(), %{"title" => "Third", "assignees" => ["ada-assignee"]})

    # A closed issue still counts: the view lists `state: "all"`.
    {:ok, _} = Issues.update_issue(third, %{"state" => "closed"})

    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/assignees")

    assert has_element?(view, "#assignees")
    refute html =~ "No assignees have been assigned"

    # Rows are sorted by descending count.
    assert has_element?(view, "#assignees tr:first-child td:first-child", "ada-assignee")
    assert has_element?(view, "#assignees tr:first-child td:nth-child(2)", "3")
    assert has_element?(view, "#assignees tr:nth-child(2) td:first-child", "grace-assignee")
    assert has_element?(view, "#assignees tr:nth-child(2) td:nth-child(2)", "1")
    refute has_element?(view, "#assignees tr:nth-child(3)")
  end

  test "an anonymous visitor is redirected away from the assignee list" do
    assert {:error, {:redirect, %{to: to}}} =
             live(build_conn(), ~p"/OpenAgentsInc/openagents.com/assignees")

    refute to == "/OpenAgentsInc/openagents.com/assignees"
  end

  defp repository do
    OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
