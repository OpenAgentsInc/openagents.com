defmodule OpenAgents.IssueProgressTest do
  use OpenAgents.DataCase

  import Ecto.Query
  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Issues
  alias OpenAgents.ProjectItems
  alias OpenAgents.Projects
  alias OpenAgents.Threads
  alias OpenAgents.Threads.Thread
  alias OpenAgents.Transparency.ArtifactLink

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

  describe "an attempt holding the issue" do
    test "starts the issue with no board anywhere", %{repository: repository} do
      {:ok, issue} = Issues.create_issue(repository, %{title: "Picked up"})
      {:ok, untouched} = Issues.create_issue(repository, %{title: "Nobody has touched this"})

      attempt(repository, issue, state: "running")

      assert Issues.progress(issue) == "in_progress"
      assert Issues.progress(untouched) == "to_do"
    end

    test "an admitted attempt has started it too", %{repository: repository} do
      {:ok, issue} = Issues.create_issue(repository, %{title: "Admitted"})
      attempt(repository, issue, state: "admitted")

      assert Issues.progress(issue) == "in_progress"
    end

    test "a terminal attempt has released the claim", %{repository: repository} do
      for state <- ~w(completed failed cancelled) do
        {:ok, issue} = Issues.create_issue(repository, %{title: "Attempt #{state}"})
        attempt(repository, issue, state: state)

        assert Issues.progress(issue) == "to_do", "expected #{state} to stop claiming"
      end
    end

    test "an attempt past its deadline stops claiming work", %{repository: repository} do
      {:ok, issue} = Issues.create_issue(repository, %{title: "Ran over"})

      attempt(repository, issue,
        state: "running",
        deadline_at: DateTime.add(DateTime.utc_now(), -60, :second)
      )

      assert Issues.progress(issue) == "to_do"
    end

    test "a dark attempt is withheld rather than published as progress", %{
      repository: repository
    } do
      {:ok, issue} = Issues.create_issue(repository, %{title: "Withheld"})
      attempt(repository, issue, state: "running", transparency_tier: "dark")

      assert Issues.progress(issue) == "to_do"
    end

    test "a revoked artifact link takes the attempt out of the projection", %{
      repository: repository
    } do
      user = github_user("issue-progress-revoked")
      {:ok, issue} = Issues.create_issue(repository, %{title: "Revoked"})

      link =
        Repo.insert!(%ArtifactLink{
          account_id: user.id,
          artifact_type: "changelog",
          artifact_ref: "sha",
          repository_id: repository.id,
          tier: "ledger",
          revoked_at: DateTime.utc_now()
        })

      attempt(repository, issue, state: "running", artifact_link_id: link.id)

      assert Issues.progress(issue) == "to_do"
    end

    test "the filter lists exactly what the derived value calls started", %{
      repository: repository
    } do
      {:ok, started} = Issues.create_issue(repository, %{title: "Started"})
      {:ok, _queued} = Issues.create_issue(repository, %{title: "Queued"})
      attempt(repository, started, state: "running")

      assert {[found], 1} = Issues.list_issues_page(repository, progress: "in_progress")
      assert found.id == started.id

      {queued, _total} = Issues.list_issues_page(repository, progress: "to_do")
      assert Enum.map(queued, & &1.title) == ["Queued"]
    end
  end

  describe "a session bound to the issue" do
    test "an open thread starts the issue for the account running it", %{
      repository: repository
    } do
      user = github_user("issue-progress-owner")
      {:ok, issue} = Issues.create_issue(repository, %{title: "Being worked"})
      {:ok, untouched} = Issues.create_issue(repository, %{title: "Untouched"})

      {:ok, _thread} = Threads.open(user, "Implement it", issue_id: issue.id)

      assert Issues.progress(issue, user) == "in_progress"
      assert Issues.progress(untouched, user) == "to_do"
    end

    test "a thread that has gone quiet stops claiming the issue", %{repository: repository} do
      user = github_user("issue-progress-quiet")
      {:ok, issue} = Issues.create_issue(repository, %{title: "Walked away from"})

      {:ok, thread} = Threads.open(user, "Implement it", issue_id: issue.id)
      assert Issues.progress(issue, user) == "in_progress"

      go_quiet(thread)

      assert Issues.progress(issue, user) == "to_do"
      assert Repo.get!(Thread, thread.id).status == "open"
    end

    test "a finished thread stops claiming the issue", %{repository: repository} do
      user = github_user("issue-progress-finished")
      {:ok, issue} = Issues.create_issue(repository, %{title: "Session over"})

      {:ok, thread} = Threads.open(user, "Implement it", issue_id: issue.id)
      {:ok, _cancelled} = Threads.cancel(thread, "Done with it.")

      assert Issues.progress(issue, user) == "to_do"
    end

    test "an owner-only thread never becomes another reader's fact", %{repository: repository} do
      user = github_user("issue-progress-private")
      stranger = github_user("issue-progress-stranger")
      {:ok, issue} = Issues.create_issue(repository, %{title: "Privately worked"})

      {:ok, _dark} = Threads.open(user, "Implement it", issue_id: issue.id)

      assert Issues.progress(issue, user) == "in_progress"
      assert Issues.progress(issue, stranger) == "to_do"
      assert Issues.progress(issue, nil) == "to_do"
    end

    test "a thread opened at a wider tier reaches every reader", %{repository: repository} do
      user = github_user("issue-progress-wide")
      stranger = github_user("issue-progress-wide-stranger")
      {:ok, issue} = Issues.create_issue(repository, %{title: "Openly worked"})

      {:ok, _ledger} =
        Threads.open(user, "Implement it", issue_id: issue.id, visibility: "ledger")

      assert Issues.progress(issue, user) == "in_progress"
      assert Issues.progress(issue, stranger) == "in_progress"
      assert Issues.progress(issue, nil) == "in_progress"
    end

    test "the filter reads the same threads the derived value does", %{repository: repository} do
      user = github_user("issue-progress-filter")
      stranger = github_user("issue-progress-filter-stranger")
      {:ok, started} = Issues.create_issue(repository, %{title: "Started"})
      {:ok, _queued} = Issues.create_issue(repository, %{title: "Queued"})

      {:ok, _thread} = Threads.open(user, "Implement it", issue_id: started.id)

      assert {[found], 1} =
               Issues.list_issues_page(repository, progress: "in_progress", reader: user)

      assert found.id == started.id

      assert {[], 0} =
               Issues.list_issues_page(repository, progress: "in_progress", reader: stranger)

      {queued, _total} =
        Issues.list_issues_page(repository, progress: "to_do", reader: stranger)

      assert Enum.map(queued, & &1.title) |> Enum.sort() == ["Queued", "Started"]
    end
  end

  describe "binding a session to the issue its objective names" do
    test "an objective naming an issue in the thread's repository binds it", %{
      repository: repository
    } do
      user = github_user("issue-bind-owner")
      {:ok, issue} = Issues.create_issue(repository, %{title: "Named by the prompt"})
      path = "#{repository.owner}/#{repository.name}"

      {:ok, thread} =
        Threads.open(user, "Implement issue ##{issue.number} and close it", repository: path)

      assert thread.issue_id == issue.id
      assert Issues.progress(issue, user) == "in_progress"
    end

    test "the qualified form binds when it names the same repository", %{
      repository: repository
    } do
      user = github_user("issue-bind-qualified")
      {:ok, issue} = Issues.create_issue(repository, %{title: "Named in full"})
      path = "#{repository.owner}/#{repository.name}"

      {:ok, thread} = Threads.open(user, "Work #{path}##{issue.number}", repository: path)

      assert thread.issue_id == issue.id
    end

    test "a reference to another repository binds nothing", %{repository: repository} do
      user = github_user("issue-bind-cross")
      other = repository_fixture()
      {:ok, elsewhere} = Issues.create_issue(other, %{title: "Somewhere else"})

      {:ok, thread} =
        Threads.open(
          user,
          "Work #{other.owner}/#{other.name}##{elsewhere.number}",
          repository: "#{repository.owner}/#{repository.name}"
        )

      assert is_nil(thread.issue_id)
    end

    test "a thread naming no repository binds nothing", %{repository: repository} do
      user = github_user("issue-bind-unscoped")
      {:ok, issue} = Issues.create_issue(repository, %{title: "Unreachable"})

      {:ok, thread} = Threads.open(user, "Implement issue ##{issue.number}")

      assert is_nil(thread.issue_id)
    end

    test "an issue the opener cannot read binds nothing" do
      private = repository_fixture(%{visibility: "private"})
      outsider = github_user("issue-bind-outsider")
      {:ok, issue} = Issues.create_issue(private, %{title: "Private work"})

      {:ok, thread} =
        Threads.open(outsider, "Implement issue ##{issue.number}",
          repository: "#{private.owner}/#{private.name}"
        )

      assert is_nil(thread.issue_id)
    end

    test "a number naming no issue binds nothing", %{repository: repository} do
      user = github_user("issue-bind-missing")

      {:ok, thread} =
        Threads.open(user, "Implement issue #999999",
          repository: "#{repository.owner}/#{repository.name}"
        )

      assert is_nil(thread.issue_id)
    end
  end

  defp attempt(repository, issue, overrides) do
    now = DateTime.utc_now()

    defaults = [
      repository_id: repository.id,
      issue_id: issue.id,
      target_kind: "computer",
      requesting_principal: %{"kind" => "test"},
      branch: "work/#{issue.number}-#{System.unique_integer([:positive])}",
      state: "running",
      transparency_tier: "ledger",
      deadline_at: DateTime.add(now, 3600, :second),
      admitted_at: now,
      started_at: now
    ]

    Repo.insert!(struct!(Assignment, Keyword.merge(defaults, overrides)))
  end

  # Silence, not a status change: the thread stays open and simply records
  # nothing for longer than the quiet window.
  defp go_quiet(%Thread{id: id}) do
    quiet = DateTime.add(DateTime.utc_now(), -3 * 60 * 60, :second)

    {1, _} =
      Repo.update_all(from(thread in Thread, where: thread.id == ^id),
        set: [updated_at: quiet]
      )
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
