defmodule OpenAgentsWeb.AssigneeControllerTest do
  use OpenAgentsWeb.ConnCase

  import OpenAgents.AccountsFixtures

  describe "index" do
    test "GET /api/v1/repos/:owner/:repo/assignees returns the assignable list", %{conn: conn} do
      user = repository_user_fixture("octocat")
      {:ok, _membership} = OpenAgents.Repositories.add_member(repository(), user, "contributor")
      conn = get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/assignees")

      assert %{"assignees" => [%{"login" => "octocat"}]} = json_response(conn, 200)
    end
  end

  describe "show" do
    test "GET /api/v1/repos/:owner/:repo/assignees/:assignee returns an assignable user",
         %{conn: conn} do
      user = repository_user_fixture("octocat")
      {:ok, _membership} = OpenAgents.Repositories.add_member(repository(), user, "contributor")
      conn = get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/assignees/octocat")

      assert %{"login" => "octocat"} = json_response(conn, 200)
    end

    test "GET /api/v1/repos/:owner/:repo/assignees/:assignee hides a nonmember", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/assignees/not-a-member")

      assert_api_error(conn, 404, "not_found")
    end
  end

  defp repository do
    OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
