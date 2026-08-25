defmodule OpenAgentsWeb.RepositoryIsolationControllerTest do
  use OpenAgentsWeb.ConnCase

  alias OpenAgents.Issues
  alias OpenAgents.Labels
  alias OpenAgents.Milestones
  alias OpenAgents.Repositories

  setup %{conn: conn} do
    conn = put_forge_api_token(conn, "repository-isolation")
    initial = Repositories.get_by_path!("OpenAgentsInc", "openagents.com")

    {:ok, second} =
      Repositories.create_repository(%{
        owner: "SecondOrg",
        name: "second-repo",
        visibility: "public",
        default_branch: "main"
      })

    {:ok, initial_issue} = Issues.create_issue(initial, %{title: "Initial issue"})
    {:ok, second_issue} = Issues.create_issue(second, %{title: "Second issue"})

    %{
      conn: conn,
      initial: initial,
      second: second,
      initial_issue: initial_issue,
      second_issue: second_issue
    }
  end

  test "the same issue number resolves only inside the requested repository", %{
    conn: conn,
    initial_issue: initial_issue,
    second_issue: second_issue
  } do
    assert initial_issue.number == second_issue.number

    assert get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/issues/1")
           |> json_response(200)
           |> Map.fetch!("title") == "Initial issue"

    assert get(recycle(conn), ~p"/api/v1/repos/SecondOrg/second-repo/issues/1")
           |> json_response(200)
           |> Map.fetch!("title") == "Second issue"
  end

  test "an initial-repository token cannot mutate a repository it has not joined", %{
    conn: conn,
    second_issue: second_issue
  } do
    assert patch(conn, ~p"/api/v1/repos/SecondOrg/second-repo/issues/1", %{title: "Crossed"})
           |> api_error_code(404) == "not_found"

    assert Issues.get_issue_by_path!("SecondOrg", "second-repo", 1).title == second_issue.title
  end

  test "labels and milestones with equal identifiers render from the requested repository", %{
    conn: conn,
    initial: initial,
    second: second
  } do
    {:ok, _initial_label} = Labels.create_label(initial, %{name: "priority", color: "111111"})
    {:ok, _second_label} = Labels.create_label(second, %{name: "priority", color: "222222"})
    {:ok, _initial_milestone} = Milestones.create_milestone(initial, %{title: "Initial M"})
    {:ok, _second_milestone} = Milestones.create_milestone(second, %{title: "Second M"})

    assert get(conn, ~p"/api/v1/repos/SecondOrg/second-repo/labels/priority")
           |> json_response(200)
           |> Map.fetch!("color") == "222222"

    assert get(recycle(conn), ~p"/api/v1/repos/SecondOrg/second-repo/milestones/1")
           |> json_response(200)
           |> Map.fetch!("title") == "Second M"
  end

  test "a resource cannot be read through an unknown repository path", %{conn: conn} do
    assert get(conn, ~p"/api/v1/repos/Unknown/nope/issues/1")
           |> api_error_code(404) == "not_found"
  end

  test "anonymous API reads do not expose a private repository", %{conn: conn} do
    {:ok, private_repository} =
      Repositories.create_repository(%{
        owner: "PrivateOrg",
        name: "private-repo",
        visibility: "private",
        default_branch: "main"
      })

    assert {:ok, _issue} = Issues.create_issue(private_repository, %{title: "Private"})

    assert get(conn, ~p"/api/v1/repos/PrivateOrg/private-repo/issues/1")
           |> api_error_code(404) == "not_found"
  end
end
