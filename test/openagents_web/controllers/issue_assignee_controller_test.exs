defmodule OpenAgentsWeb.IssueAssigneeControllerTest do
  use OpenAgentsWeb.ConnCase

  setup %{conn: conn}, do: {:ok, conn: put_forge_api_token(conn, "issue-assignees", repository())}

  alias OpenAgents.Issues
  import OpenAgents.AccountsFixtures

  setup do
    for login <- ["octocat", "hubot"] do
      user = repository_user_fixture(login)
      {:ok, _membership} = OpenAgents.Repositories.add_member(repository(), user, "contributor")
    end

    {:ok, issue} = Issues.create_issue(repository(), %{title: "Assignable issue"})
    %{issue: issue}
  end

  describe "index" do
    test "GET .../issues/:issue_number/assignees returns an empty list for a fresh issue", %{
      conn: conn,
      issue: issue
    } do
      conn =
        get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/assignees")

      assert json_response(conn, 200) == %{"assignees" => []}
    end

    test "GET .../issues/:issue_number/assignees lists current assignees", %{
      conn: conn,
      issue: issue
    } do
      {:ok, _issue} = Issues.add_assignees(issue, ["octocat"])

      conn =
        get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/assignees")

      assert %{"assignees" => [assignee]} = json_response(conn, 200)
      assert assignee["login"] == "octocat"
    end

    test "GET .../issues/:issue_number/assignees returns 404 for a missing issue", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/999999/assignees")

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "create" do
    test "POST .../issues/:issue_number/assignees adds an assignee", %{conn: conn, issue: issue} do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/assignees",
          %{
            assignees: ["octocat"]
          }
        )

      assert %{"assignees" => [%{"login" => "octocat"}]} = json_response(conn, 200)

      assert [%{"login" => "octocat"}] =
               Issues.get_issue_by_number!(repository(), issue.number).assignees
    end

    test "POST .../issues/:issue_number/assignees adds several at once", %{
      conn: conn,
      issue: issue
    } do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/assignees",
          %{
            assignees: ["octocat", "hubot"]
          }
        )

      assert %{"assignees" => assignees} = json_response(conn, 200)
      assert Enum.map(assignees, & &1["login"]) == ["octocat", "hubot"]
    end

    test "POST .../issues/:issue_number/assignees does not duplicate an existing assignee", %{
      conn: conn,
      issue: issue
    } do
      {:ok, _issue} = Issues.add_assignees(issue, ["octocat"])

      conn =
        post(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/assignees",
          %{
            assignees: ["octocat"]
          }
        )

      assert %{"assignees" => [_only_one]} = json_response(conn, 200)
    end

    test "POST .../issues/:issue_number/assignees with no assignees leaves the issue unchanged",
         %{conn: conn, issue: issue} do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/assignees",
          %{}
        )

      assert json_response(conn, 200) == %{"assignees" => []}
    end

    test "POST .../issues/:issue_number/assignees returns 404 for a missing issue", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/999999/assignees", %{
          assignees: ["octocat"]
        })

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "delete" do
    test "DELETE .../issues/:issue_number/assignees removes the named assignees", %{
      conn: conn,
      issue: issue
    } do
      {:ok, _issue} = Issues.add_assignees(issue, ["octocat", "hubot"])

      conn =
        delete(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/assignees",
          %{
            assignees: ["octocat"]
          }
        )

      assert %{"assignees" => [%{"login" => "hubot"}]} = json_response(conn, 200)

      assert [%{"login" => "hubot"}] =
               Issues.get_issue_by_number!(repository(), issue.number).assignees
    end

    test "DELETE .../issues/:issue_number/assignees ignores an assignee that is not set", %{
      conn: conn,
      issue: issue
    } do
      {:ok, _issue} = Issues.add_assignees(issue, ["octocat"])

      conn =
        delete(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/assignees",
          %{
            assignees: ["nobody"]
          }
        )

      assert %{"assignees" => [%{"login" => "octocat"}]} = json_response(conn, 200)
    end

    test "DELETE .../issues/:issue_number/assignees returns 404 for a missing issue", %{
      conn: conn
    } do
      conn =
        delete(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/999999/assignees", %{
          assignees: ["octocat"]
        })

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  defp repository do
    OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
