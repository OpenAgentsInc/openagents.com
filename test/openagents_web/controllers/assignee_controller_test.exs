defmodule OpenAgentsWeb.AssigneeControllerTest do
  use OpenAgentsWeb.ConnCase

  import OpenAgents.AccountsFixtures

  describe "index" do
    test "GET /api/v3/repos/:owner/:repo/assignees returns the assignable list", %{conn: conn} do
      repository_user_fixture("octocat")
      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/assignees")

      assert %{"assignees" => [%{"login" => "octocat"}]} = json_response(conn, 200)
    end
  end

  describe "show" do
    test "GET /api/v3/repos/:owner/:repo/assignees/:assignee returns an assignable user",
         %{conn: conn} do
      repository_user_fixture("octocat")
      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/assignees/octocat")

      assert %{"login" => "octocat"} = json_response(conn, 200)
    end

    test "GET /api/v3/repos/:owner/:repo/assignees/:assignee hides a nonmember", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/assignees/not-a-member")

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end
end
