defmodule OpenAgents.IssueProgressTest do
  use OpenAgents.DataCase

  alias OpenAgents.Issues
  alias OpenAgents.ProjectItems
  alias OpenAgents.Projects

  setup do
    {:ok, repository: repository_fixture()}
  end

  describe "progress_map/2" do
    test "an issue on no board has not started", %{repository: repository} do
      {:ok, issue} = Issues.create_issue(repository, %{title: "Untouched"})

      assert %{issue.id => "to_do"} == Issues.progress_map([issue])
    end

    test "a started column on a readable board reports in_progress", %{repository: repository} do
      {:ok, issue} = Issues.create_issue(repository, %{title: "Underway"})
      place(repository, issue, "In Progress")

      assert Issues.progress(issue) == "in_progress"
    end

    test "column matching ignores case and separators", %{repository: repository} do
      for column <- ["in progress", "IN_PROGRESS", " In-Progress ", "In Review", "Started"] do
        {:ok, issue} = Issues.create_issue(repository, %{title: "Underway in #{column}"})
        place(repository, issue, column)

        assert Issues.progress(issue) == "in_progress", "expected #{inspect(column)} to start"
      end
    end

    test "a column no board column names leaves the issue to_do", %{repository: repository} do
      {:ok, issue} = Issues.create_issue(repository, %{title: "Queued"})
      place(repository, issue, "To Do")

      assert Issues.progress(issue) == "to_do"
    end

    test "closing the issue is what finishes it", %{repository: repository} do
      {:ok, issue} = Issues.create_issue(repository, %{title: "Underway"})
      place(repository, issue, "In Progress")

      {:ok, closed} = Issues.update_issue(issue, %{"state" => "closed"})

      assert Issues.progress(closed) == "done"
    end

    test "a Done column on an open issue does not finish it", %{repository: repository} do
      {:ok, issue} = Issues.create_issue(repository, %{title: "Says done, still open"})
      place(repository, issue, "Done")

      assert Issues.progress(issue) == "to_do"
    end

    test "a private board's column never reaches a reader without membership" do
      public = repository_fixture(%{visibility: "public"})
      private = repository_fixture(%{visibility: "private"})
      member = repository_user_fixture("board-member")
      {:ok, _membership} = OpenAgents.Repositories.add_member(private, member, "owner")

      {:ok, issue} = Issues.create_issue(public, %{title: "Tracked privately"})
      place(private, issue, "In Progress")

      assert Issues.progress(issue, nil) == "to_do"
      assert Issues.progress(issue, repository_user_fixture("outsider")) == "to_do"
      assert Issues.progress(issue, member) == "in_progress"
    end

    test "one query serves a whole page", %{repository: repository} do
      {:ok, started} = Issues.create_issue(repository, %{title: "Started"})
      {:ok, queued} = Issues.create_issue(repository, %{title: "Queued"})
      {:ok, finished} = Issues.create_issue(repository, %{title: "Finished", state: "closed"})
      place(repository, started, "In Progress")

      progress = Issues.progress_map([started, queued, finished])

      assert progress[started.id] == "in_progress"
      assert progress[queued.id] == "to_do"
      assert progress[finished.id] == "done"
    end
  end

  describe "the progress filter" do
    test "lists exactly the issues the derived value calls started", %{repository: repository} do
      {:ok, started} = Issues.create_issue(repository, %{title: "Started"})
      {:ok, _queued} = Issues.create_issue(repository, %{title: "Queued"})
      place(repository, started, "In Progress")

      {issues, total} =
        Issues.list_issues_page(repository, state: "all", progress: "in_progress")

      assert total == 1
      assert Enum.map(issues, & &1.title) == ["Started"]
    end

    test "to_do is the complement within the open issues", %{repository: repository} do
      {:ok, started} = Issues.create_issue(repository, %{title: "Started"})
      {:ok, _queued} = Issues.create_issue(repository, %{title: "Queued"})
      place(repository, started, "In Progress")

      {issues, _total} = Issues.list_issues_page(repository, state: "open", progress: "to_do")

      assert Enum.map(issues, & &1.title) == ["Queued"]
    end

    test "done lists the closed issues", %{repository: repository} do
      {:ok, _open} = Issues.create_issue(repository, %{title: "Open"})
      {:ok, _closed} = Issues.create_issue(repository, %{title: "Closed", state: "closed"})

      {issues, _total} = Issues.list_issues_page(repository, state: "all", progress: "done")

      assert Enum.map(issues, & &1.title) == ["Closed"]
    end

    test "a private board cannot move an issue into another reader's list" do
      public = repository_fixture(%{visibility: "public"})
      private = repository_fixture(%{visibility: "private"})
      member = repository_user_fixture("filter-member")
      {:ok, _membership} = OpenAgents.Repositories.add_member(private, member, "owner")

      {:ok, issue} = Issues.create_issue(public, %{title: "Tracked privately"})
      place(private, issue, "In Progress")

      assert {[], 0} = Issues.list_issues_page(public, progress: "in_progress", reader: nil)

      assert {[found], 1} =
               Issues.list_issues_page(public, progress: "in_progress", reader: member)

      assert found.id == issue.id
    end
  end

  defp place(board_repository, issue, column) do
    {:ok, project} =
      Projects.create_project(board_repository, %{title: "Board", owner: "OpenAgents"})

    {:ok, item} =
      ProjectItems.create_project_item(board_repository, %{
        project_id: project.id,
        issue_id: issue.id,
        issue_repository_id: issue.repository_id,
        values: %{"Status" => column}
      })

    item
  end
end
