defmodule OpenAgentsWeb.AssigneeControllerTest do
  use OpenAgentsWeb.ConnCase

  describe "index" do
    test "GET /api/v3/repos/:owner/:repo/assignees returns the assignable list", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/repos/OpenAgents/openagents/assignees")

      assert json_response(conn, 200) == %{"assignees" => []}
    end
  end

  describe "show" do
    test "GET /api/v3/repos/:owner/:repo/assignees/:assignee returns 404 for a user who cannot be assigned",
         %{conn: conn} do
      conn = get(conn, ~p"/api/v3/repos/OpenAgents/openagents/assignees/octocat")

      assert response(conn, 404) == ""
    end
  end
end
