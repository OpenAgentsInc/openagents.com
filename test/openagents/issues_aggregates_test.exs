defmodule OpenAgents.IssuesAggregatesTest do
  @moduledoc """
  The counts the assignee and milestone indexes print (#159).

  Both pages measured a collection by loading it: every issue in the
  repository, in memory, once per visit. `93c3383` removed that read from the
  homepage, and a page that follows the issues it counts would pay it once per
  write instead. These are the grouped aggregates that replaced it.
  """

  use OpenAgents.DataCase

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Milestones
  alias OpenAgents.Repositories

  setup do
    author = repository_user_fixture("issues-aggregate-author")
    helper = repository_user_fixture("issues-aggregate-helper")
    repository = repository_with_member_fixture(author)
    {:ok, _membership} = Repositories.add_member(repository, helper, "contributor")

    %{repository: repository, author: author, helper: helper}
  end

  describe "count_issues_by_assignee/1" do
    test "counts each login once per issue, most assigned first", context do
      %{author: author, helper: helper} = context

      {:ok, _one} =
        Issues.create_issue(
          context.repository,
          %{"title" => "One", "assignees" => [author.github_login, helper.github_login]},
          author
        )

      {:ok, _two} =
        Issues.create_issue(
          context.repository,
          %{"title" => "Two", "assignees" => [author.github_login]},
          author
        )

      assert [{first, 2}, {second, 1}] = Issues.count_issues_by_assignee(context.repository)
      assert first == author.github_login
      assert second == helper.github_login
    end

    test "counts closed issues too, and unassigned ones not at all", context do
      author = context.author

      {:ok, closed} =
        Issues.create_issue(
          context.repository,
          %{"title" => "Closed", "assignees" => [author.github_login]},
          author
        )

      {:ok, _} = Issues.update_issue(closed, %{"state" => "closed"}, author)
      {:ok, _unassigned} = Issues.create_issue(context.repository, %{"title" => "Nobody"}, author)

      assert [{login, 1}] = Issues.count_issues_by_assignee(context.repository)
      assert login == author.github_login
    end
  end

  describe "count_issues_by_milestone/1" do
    test "splits each milestone's issues by state", context do
      author = context.author

      {:ok, milestone} =
        Milestones.create_milestone(context.repository, %{"title" => "v1"}, author)

      {:ok, _open} =
        Issues.create_issue(
          context.repository,
          %{"title" => "Still open", "milestone" => milestone.number},
          author
        )

      {:ok, closed} =
        Issues.create_issue(
          context.repository,
          %{"title" => "Done", "milestone" => milestone.number},
          author
        )

      {:ok, _} = Issues.update_issue(closed, %{"state" => "closed"}, author)
      {:ok, _none} = Issues.create_issue(context.repository, %{"title" => "No milestone"}, author)

      counts = Issues.count_issues_by_milestone(context.repository)

      assert counts[milestone.number] == %{open: 1, closed: 1}
      assert map_size(counts) == 1
    end
  end

  describe "list_issue_options/1" do
    test "labels each issue by number and title, newest first", context do
      author = context.author
      {:ok, first} = Issues.create_issue(context.repository, %{"title" => "First"}, author)
      {:ok, second} = Issues.create_issue(context.repository, %{"title" => "Second"}, author)

      assert [{second_label, second_number}, {first_label, first_number}] =
               Issues.list_issue_options(context.repository)

      assert second_number == second.number
      assert second_label == "##{second.number} Second"
      assert first_number == first.number
      assert first_label == "##{first.number} First"
    end
  end
end
