defmodule OpenAgents.PullRequestsTest do
  use OpenAgents.DataCase

  alias OpenAgents.PullRequests
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Repositories

  import OpenAgents.AccountsFixtures
  import OpenAgents.IssuesFixtures

  test "new repositories allow pull requests by default" do
    assert repository_fixture().pull_requests_enabled
  end

  test "the canonical repository has pull requests disabled" do
    repository = Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
    refute repository.pull_requests_enabled
  end

  test "a disabled repository refuses a new pull request before creating its issue" do
    user = repository_user_fixture("pull-request-author")
    repository = repository_fixture(%{pull_requests_enabled: false})

    assert {:error, :pull_requests_disabled} = PullRequests.create(repository, %{}, user)
  end

  test "only an owner can update the repository pull request setting" do
    owner = repository_user_fixture("pull-request-owner")
    maintainer = repository_user_fixture("pull-request-maintainer")
    repository = repository_with_member_fixture(owner)
    {:ok, _membership} = Repositories.add_member(repository, maintainer, "maintainer")

    assert {:ok, updated} =
             Repositories.update_pull_request_setting(
               repository.owner,
               repository.name,
               owner,
               false
             )

    refute updated.pull_requests_enabled

    assert {:error, :forbidden} =
             Repositories.update_pull_request_setting(
               repository.owner,
               repository.name,
               maintainer,
               true
             )
  end

  test "an open head and base pair can have only one pull request" do
    target = repository_fixture()
    source = repository_fixture()
    first_issue = issue_fixture(target, %{title: "First pull request"})
    second_issue = issue_fixture(target, %{title: "Second pull request"})

    attrs = %{
      repository_id: target.id,
      head_repository_id: source.id,
      head_ref: "feature",
      head_sha: String.duplicate("a", 40),
      base_ref: "main",
      base_sha: String.duplicate("b", 40),
      state: "open"
    }

    assert {:ok, _pull_request} =
             %PullRequest{}
             |> PullRequest.changeset(Map.put(attrs, :issue_id, first_issue.id))
             |> Repo.insert()

    assert {:error, changeset} =
             %PullRequest{}
             |> PullRequest.changeset(Map.put(attrs, :issue_id, second_issue.id))
             |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).repository_id
  end
end
