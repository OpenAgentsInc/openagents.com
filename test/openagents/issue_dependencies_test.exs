defmodule OpenAgents.IssueDependenciesTest do
  use OpenAgents.DataCase

  alias OpenAgents.Issues

  setup do
    {:ok, repository: repository_fixture()}
  end

  describe "add_dependencies/3" do
    test "records a prerequisite in both directions", %{repository: repository} do
      {:ok, blocked} = Issues.create_issue(repository, %{title: "Aim agents at the backlog"})
      {:ok, blocker} = Issues.create_issue(repository, %{title: "Deliver the work system"})

      assert :ok = Issues.add_dependencies(blocked, [blocker.number])

      assert %{blocked: true, blocked_by: [%{number: blocker_number, state: "open"}], blocks: []} =
               Issues.dependencies(blocked)

      assert blocker_number == blocker.number

      assert %{blocked: false, blocked_by: [], blocks: [%{number: blocked_number}]} =
               Issues.dependencies(blocker)

      assert blocked_number == blocked.number
    end

    test "recording the same prerequisite twice leaves one edge", %{repository: repository} do
      {:ok, blocked} = Issues.create_issue(repository, %{title: "Second"})
      {:ok, blocker} = Issues.create_issue(repository, %{title: "First"})

      assert :ok = Issues.add_dependencies(blocked, [blocker.number])
      assert :ok = Issues.add_dependencies(blocked, [blocker.number])

      assert %{blocked_by: [_one]} = Issues.dependencies(blocked)
    end

    test "one unknown number records none of the batch", %{repository: repository} do
      {:ok, blocked} = Issues.create_issue(repository, %{title: "Blocked"})
      {:ok, blocker} = Issues.create_issue(repository, %{title: "Blocker"})

      assert {:error, {:missing_issue, 4_242}} =
               Issues.add_dependencies(blocked, [blocker.number, 4_242])

      assert %{blocked: false, blocked_by: []} = Issues.dependencies(blocked)
    end

    test "an issue in another repository is not a prerequisite here", %{repository: repository} do
      other_repository = repository_fixture()
      {:ok, blocked} = Issues.create_issue(repository, %{title: "Local"})
      {:ok, _first} = Issues.create_issue(other_repository, %{title: "First elsewhere"})
      {:ok, elsewhere} = Issues.create_issue(other_repository, %{title: "Elsewhere"})

      refute elsewhere.number == blocked.number

      assert {:error, {:missing_issue, number}} =
               Issues.add_dependencies(blocked, [elsewhere.number])

      assert number == elsewhere.number
    end

    test "an issue cannot be its own prerequisite", %{repository: repository} do
      {:ok, issue} = Issues.create_issue(repository, %{title: "Alone"})

      assert {:error, {:self_reference, number}} =
               Issues.add_dependencies(issue, [issue.number])

      assert number == issue.number
    end

    test "a value that is not an issue number is refused", %{repository: repository} do
      {:ok, issue} = Issues.create_issue(repository, %{title: "Alone"})

      assert {:error, {:invalid_number, "soon"}} = Issues.add_dependencies(issue, ["soon"])
    end

    test "an edge that would close a cycle is refused", %{repository: repository} do
      {:ok, first} = Issues.create_issue(repository, %{title: "First"})
      {:ok, second} = Issues.create_issue(repository, %{title: "Second"})
      {:ok, third} = Issues.create_issue(repository, %{title: "Third"})

      assert :ok = Issues.add_dependencies(second, [first.number])
      assert :ok = Issues.add_dependencies(third, [second.number])

      assert {:error, {:cycle, path}} = Issues.add_dependencies(first, [third.number])
      assert path == [first.number, third.number, second.number, first.number]

      assert %{blocked_by: []} = Issues.dependencies(first)
    end
  end

  describe "derived blocked state" do
    test "closing the last prerequisite unblocks the issue", %{repository: repository} do
      {:ok, blocked} = Issues.create_issue(repository, %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository, %{title: "Prerequisite"})

      assert :ok = Issues.add_dependencies(blocked, [blocker.number])
      assert %{blocked: true} = Issues.dependencies(blocked)

      {:ok, blocker} = Issues.update_issue(blocker, %{"state" => "closed"})
      assert %{blocked: false, blocked_by: [%{state: "closed"}]} = Issues.dependencies(blocked)

      {:ok, _reopened} = Issues.update_issue(blocker, %{"state" => "open"})
      assert %{blocked: true} = Issues.dependencies(blocked)
    end

    test "one open prerequisite among closed ones still blocks", %{repository: repository} do
      {:ok, blocked} = Issues.create_issue(repository, %{title: "Waiting"})
      {:ok, done} = Issues.create_issue(repository, %{title: "Done", state: "closed"})
      {:ok, pending} = Issues.create_issue(repository, %{title: "Pending"})

      assert :ok = Issues.add_dependencies(blocked, [done.number, pending.number])
      assert %{blocked: true, blocked_by: [_first, _second]} = Issues.dependencies(blocked)
    end
  end

  describe "remove_dependency/2" do
    test "removes one edge and leaves the rest", %{repository: repository} do
      {:ok, blocked} = Issues.create_issue(repository, %{title: "Waiting"})
      {:ok, first} = Issues.create_issue(repository, %{title: "First"})
      {:ok, second} = Issues.create_issue(repository, %{title: "Second"})

      assert :ok = Issues.add_dependencies(blocked, [first.number, second.number])
      assert :ok = Issues.remove_dependency(blocked, first.number)

      assert %{blocked_by: [%{number: remaining}]} = Issues.dependencies(blocked)
      assert remaining == second.number
    end

    test "removing an edge that is not recorded reports the mismatch", %{
      repository: repository
    } do
      {:ok, blocked} = Issues.create_issue(repository, %{title: "Waiting"})
      {:ok, other} = Issues.create_issue(repository, %{title: "Unrelated"})

      assert {:error, {:missing_dependency, number}} =
               Issues.remove_dependency(blocked, other.number)

      assert number == other.number
    end
  end

  describe "list_issues_page/2 with the blocked filter" do
    test "blocked and unblocked partition the repository", %{repository: repository} do
      {:ok, blocked} = Issues.create_issue(repository, %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository, %{title: "Prerequisite"})
      {:ok, free} = Issues.create_issue(repository, %{title: "Ready"})

      assert :ok = Issues.add_dependencies(blocked, [blocker.number])

      assert {[%{id: id}], 1} = Issues.list_issues_page(repository, blocked: true)
      assert id == blocked.id

      {unblocked, total} = Issues.list_issues_page(repository, blocked: false)
      assert total == 2
      assert Enum.map(unblocked, & &1.id) |> Enum.sort() == Enum.sort([blocker.id, free.id])
    end

    test "closing the prerequisite moves the issue between the two lists", %{
      repository: repository
    } do
      {:ok, blocked} = Issues.create_issue(repository, %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository, %{title: "Prerequisite"})

      assert :ok = Issues.add_dependencies(blocked, [blocker.number])
      assert {_issues, 1} = Issues.list_issues_page(repository, blocked: true)

      {:ok, _closed} = Issues.update_issue(blocker, %{"state" => "closed"})

      assert {[], 0} = Issues.list_issues_page(repository, blocked: true)
      assert {[%{id: id}], 1} = Issues.list_issues_page(repository, blocked: false)
      assert id == blocked.id
    end

    test "the filter composes with the state filter", %{repository: repository} do
      {:ok, blocked} = Issues.create_issue(repository, %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository, %{title: "Prerequisite"})
      assert :ok = Issues.add_dependencies(blocked, [blocker.number])

      {:ok, _closed_blocked} = Issues.update_issue(blocked, %{"state" => "closed"})

      assert {[], 0} = Issues.list_issues_page(repository, blocked: true, state: "open")
      assert {[_issue], 1} = Issues.list_issues_page(repository, blocked: true, state: "closed")
    end
  end

  describe "dependency_graph/1" do
    test "reads a whole page of edges without walking the graph per row", %{
      repository: repository
    } do
      {:ok, blocked} = Issues.create_issue(repository, %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository, %{title: "Prerequisite"})
      {:ok, unrelated} = Issues.create_issue(repository, %{title: "Unrelated"})

      assert :ok = Issues.add_dependencies(blocked, [blocker.number])

      graph = Issues.dependency_graph([blocked, blocker, unrelated])

      assert %{blocked: true, blocked_by: [_one], blocks: []} = graph[blocked.id]
      assert %{blocked: false, blocked_by: [], blocks: [_one]} = graph[blocker.id]
      assert %{blocked: false, blocked_by: [], blocks: []} = graph[unrelated.id]
    end

    test "an empty list of issues reads no edges", %{repository: _repository} do
      assert Issues.dependency_graph([]) == %{}
    end
  end
end
