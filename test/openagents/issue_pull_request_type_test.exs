defmodule OpenAgents.IssuePullRequestTypeTest do
  @moduledoc """
  A pull request is an issue row, so a list of issues has to say which it means.

  `pull_requests.issue_id` points at an `issues` row, which is why the two
  share one number space and why PR #119 sat beside issue #114 in the issue
  list reading as a duplicate (#120). These tests pin the `:type` option that
  makes each surface state whether it means issues, pull requests, or both.
  """
  use OpenAgents.DataCase

  import OpenAgents.AccountsFixtures
  import OpenAgents.IssuesFixtures

  alias OpenAgents.Issues
  alias OpenAgents.PullRequests
  alias OpenAgents.PullRequests.PullRequest

  setup do
    target = repository_fixture()
    source = repository_fixture()

    plain = issue_fixture(target, %{title: "Plain issue"})
    proposal = issue_fixture(target, %{title: "Proposal"})
    pull_request = open_pull_request(target, source, proposal)

    %{
      target: target,
      source: source,
      plain: plain,
      proposal: proposal,
      pull_request: pull_request
    }
  end

  defp open_pull_request(target, source, issue, attrs \\ %{}) do
    %PullRequest{}
    |> PullRequest.changeset(
      Enum.into(attrs, %{
        repository_id: target.id,
        issue_id: issue.id,
        head_repository_id: source.id,
        head_ref: "feature-#{issue.number}",
        head_sha: String.duplicate("a", 40),
        base_ref: "main",
        base_sha: String.duplicate("b", 40),
        draft: false
      })
    )
    |> Repo.insert!()
  end

  defp titles(issues), do: issues |> Enum.map(& &1.title) |> Enum.sort()

  describe "the :type option" do
    test "a list of issues is issues, not issues and pull requests", %{target: target} do
      assert titles(Issues.list_issues(target)) == ["Plain issue"]
    end

    test "pull requests are reachable through the same list", %{target: target} do
      assert titles(Issues.list_issues(target, type: "pull_request")) == ["Proposal"]
    end

    test "all returns the GitHub shape: both kinds in one number space", %{target: target} do
      assert titles(Issues.list_issues(target, type: "all")) == ["Plain issue", "Proposal"]
    end

    test "the paged list and its total agree about what they exclude", %{target: target} do
      assert {[issue], 1} = Issues.list_issues_page(target, [])
      assert issue.title == "Plain issue"

      assert {_issues, 2} = Issues.list_issues_page(target, type: "all")
    end

    test "the count a nav publishes counts issues", %{target: target} do
      assert Issues.count_issues(target, state: "open") == 1
      assert Issues.count_issues(target, state: "open", type: "all") == 2
      assert Issues.count_issues(target, state: "open", type: "pull_request") == 1
    end

    test "the workspace-wide list excludes them too", %{target: target} do
      user = repository_user_fixture("type-reader")
      {:ok, _membership} = OpenAgents.Repositories.add_member(target, user, "owner")

      assert {issues, 1} = Issues.list_visible_issues_page(user, [])
      assert titles(issues) == ["Plain issue"]

      assert {_both, 2} = Issues.list_visible_issues_page(user, type: "all")
    end

    test "the filter composes with the others rather than replacing them", %{
      target: target,
      proposal: proposal
    } do
      {:ok, _closed} = Issues.update_issue(proposal, %{"state" => "closed"})

      assert Issues.count_issues(target, state: "closed", type: "all") == 1
      assert Issues.count_issues(target, state: "closed") == 0
    end
  end

  describe "pull request markers" do
    test "the four states are derived in one place", %{pull_request: pull_request} do
      assert PullRequests.state(pull_request) == "open"
      assert PullRequests.state(%{pull_request | draft: true}) == "draft"

      assert PullRequests.state(%{pull_request | state: "closed"}) == "closed"

      merged = %{pull_request | state: "closed", merged_at: DateTime.utc_now()}
      assert PullRequests.state(merged) == "merged"
    end

    test "one query marks a whole page", %{plain: plain, proposal: proposal} do
      markers = PullRequests.markers_by_issue_id([plain, proposal])

      refute Map.has_key?(markers, plain.id)
      assert %{state: "open", draft: false, merged_at: nil} = markers[proposal.id]
    end

    test "an empty page asks nothing" do
      assert PullRequests.markers_by_issue_id([]) == %{}
    end

    test "open pull requests are counted apart from open issues", %{target: target} do
      assert PullRequests.count_open(target) == 1
      assert Issues.count_issues(target, state: "open") == 1
    end
  end
end
