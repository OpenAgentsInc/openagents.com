defmodule OpenAgentsWeb.PullRequestLiveTest do
  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest
  import OpenAgents.IssuesFixtures

  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo

  test "the pull request list links to a valid browser detail page", %{conn: conn} do
    target = repository_fixture()
    source = repository_fixture()
    issue = issue_fixture(target, %{title: "Add pull requests"})

    %PullRequest{}
    |> PullRequest.changeset(%{
      repository_id: target.id,
      issue_id: issue.id,
      head_repository_id: source.id,
      head_ref: "feature",
      head_sha: String.duplicate("a", 40),
      base_ref: "main",
      base_sha: String.duplicate("b", 40)
    })
    |> Repo.insert!()

    {:ok, index, _html} = live(conn, "/#{target.owner}/#{target.name}/pulls")
    assert has_element?(index, "#pull-request-index")

    assert has_element?(
             index,
             "a[href='/#{target.owner}/#{target.name}/pulls/#{issue.number}']"
           )

    {:ok, show, _html} =
      live(conn, "/#{target.owner}/#{target.name}/pulls/#{issue.number}")

    assert has_element?(show, "#pull-request-show")
  end
end
