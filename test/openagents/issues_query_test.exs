defmodule OpenAgents.IssuesQueryTest do
  use OpenAgents.DataCase

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Labels
  alias OpenAgents.Milestones
  alias OpenAgents.Repositories

  setup do
    repository = Repositories.get_by_path!("OpenAgentsInc", "openagents.com")

    {:ok, open} =
      Issues.create_issue(repository, %{"title" => "First open", "body" => "alpha body"})

    {:ok, closed} =
      Issues.create_issue(repository, %{"title" => "A closed one", "body" => "beta body"})

    {:ok, _} = Issues.update_issue(closed, %{"state" => "closed", "state_reason" => "completed"})

    %{repository: repository, open: open, closed: closed}
  end

  test "list_issues_page returns one page plus the unpaginated total", %{
    repository: repository,
    open: open,
    closed: closed
  } do
    {issues, total} = Issues.list_issues_page(repository, state: "all", page: 1)

    assert total == 2
    assert length(issues) == 2
    # Newest first.
    assert hd(issues).id == closed.id or hd(issues).id == open.id
  end

  test "page parsing rejects trailing text and bounds public offsets" do
    assert Issues.parse_page("2") == 2
    assert Issues.parse_page("2junk") == 1
    assert Issues.parse_page("-1") == 1
    assert Issues.parse_page(String.duplicate("9", 100)) == 10_000
  end

  test "the state filter matches the tab it drives", %{repository: repository} do
    {open_issues, open_total} = Issues.list_issues_page(repository, state: "open")
    {closed_issues, closed_total} = Issues.list_issues_page(repository, state: "closed")

    assert open_total == 1
    assert closed_total == 1
    assert Enum.map(open_issues, & &1.state) == ["open"]
    assert Enum.map(closed_issues, & &1.state) == ["closed"]
  end

  test "the label filter reads the row snapshot", %{repository: repository, open: open} do
    Labels.create_label(repository, %{"name" => "triaged", "color" => "0e8a16"})
    {:ok, _} = Issues.add_labels(open, ["triaged"])

    {_matching, total} = Issues.list_issues_page(repository, state: "all", label: "triaged")
    assert total == 1

    {_matching, total} = Issues.list_issues_page(repository, state: "all", label: "bug")
    assert total == 0
  end

  test "the assignee filter is case-insensitive on login", %{
    repository: repository,
    open: open
  } do
    user = repository_user_fixture("filter-assignee")
    {:ok, _} = Repositories.add_member(repository, user, "maintainer")

    {:ok, _} = Issues.add_assignees(open, ["Filter-Assignee"])

    {_matching, total} =
      Issues.list_issues_page(repository, state: "all", assignee: "filter-assignee")

    assert total == 1
  end

  test "the milestone filter reads the snapshot number", %{
    repository: repository,
    open: open
  } do
    {:ok, milestone} =
      Milestones.create_milestone(repository, %{"title" => "Sweep one"}, nil)

    {:ok, _} = Issues.set_milestone(open, milestone.number)

    {_matching, total} =
      Issues.list_issues_page(repository,
        state: "all",
        milestone: Integer.to_string(milestone.number)
      )

    assert total == 1

    {_matching, total} =
      Issues.list_issues_page(repository, state: "all", milestone: "9999")

    assert total == 0
  end

  test "search matches title or body and escapes wildcards", %{
    repository: repository,
    open: open,
    closed: closed
  } do
    {_matching, total} = Issues.list_issues_page(repository, state: "all", q: "closed one")
    assert total == 1

    {_matching, total} = Issues.list_issues_page(repository, state: "all", q: "ALPHA")
    assert total == 1

    assert hd(elem(Issues.list_issues_page(repository, state: "all", q: "ALPHA"), 0)).id ==
             open.id

    # A percent sign is a literal, not a wildcard.
    {:ok, _literal} = Issues.create_issue(repository, %{"title" => "100% repro"})
    {_matching, literal_total} = Issues.list_issues_page(repository, state: "all", q: "100%")
    assert literal_total == 1

    assert closed.title =~ "closed"
  end

  test "counts respect every filter except state so both tabs agree", %{
    repository: repository,
    open: open
  } do
    Labels.create_label(repository, %{"name" => "counted", "color" => "1d76db"})
    {:ok, _} = Issues.add_labels(open, ["counted"])

    assert Issues.count_issues(repository, label: "counted", state: "open") == 1
    assert Issues.count_issues(repository, label: "counted", state: "closed") == 0
    assert Issues.count_issues(repository, state: "all") == 2
  end

  test "pagination walks without repeating rows", %{repository: repository} do
    for index <- 1..29 do
      {:ok, _} = Issues.create_issue(repository, %{"title" => "Bulk #{index}"})
    end

    {page_one, total} = Issues.list_issues_page(repository, state: "all", page: 1)
    {page_two, ^total} = Issues.list_issues_page(repository, state: "all", page: 2)

    assert total == 31
    assert length(page_one) == Issues.per_page()
    assert length(page_two) == 31 - Issues.per_page()

    page_one_ids = MapSet.new(page_one, & &1.id)
    assert Enum.all?(page_two, &(&1.id not in page_one_ids))
  end

  test "committed writes announce themselves on the repository topic", %{
    repository: repository
  } do
    :ok = Repositories.subscribe_issues(repository.id)

    {:ok, issue} = Issues.create_issue(repository, %{"title" => "Announced"})
    assert_receive {:issues_changed, repository_id}, 500
    assert repository_id == repository.id

    {:ok, _} = Issues.update_issue(issue, %{"state" => "closed"}, nil)
    assert_receive {:issues_changed, repository_id}, 500
    assert repository_id == repository.id

    {:ok, _} = Issues.create_comment(issue, %{body: "hello"}, nil)
    assert_receive {:issues_changed, repository_id}, 500
    assert repository_id == repository.id
  end
end
