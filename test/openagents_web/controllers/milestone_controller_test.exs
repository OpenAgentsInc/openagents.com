defmodule OpenAgentsWeb.MilestoneControllerTest do
  use OpenAgentsWeb.ConnCase

  setup %{conn: conn}, do: {:ok, conn: put_forge_api_token(conn, "milestones")}

  import OpenAgents.MilestonesFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Milestones

  describe "index" do
    test "GET /api/v3/repos/:owner/:repo/milestones lists milestones", %{conn: conn} do
      milestone_fixture(%{title: "v1.0", state: "open"})

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones")

      assert %{"milestones" => [milestone]} = json_response(conn, 200)
      assert milestone["title"] == "v1.0"
      assert milestone["state"] == "open"
    end

    test "GET /api/v3/repos/:owner/:repo/milestones renders issue counts and url", %{conn: conn} do
      milestone = milestone_fixture(%{title: "v1.0"})
      {:ok, _open_issue} = Issues.create_issue(%{title: "Open", milestone: milestone.number})

      {:ok, _closed_issue} =
        Issues.create_issue(%{title: "Closed", milestone: milestone.number, state: "closed"})

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones")

      assert %{"milestones" => [rendered]} = json_response(conn, 200)
      assert rendered["open_issues"] == 1
      assert rendered["closed_issues"] == 1

      assert rendered["url"] ==
               "https://openagents.com/api/v3/repos/OpenAgentsInc/openagents.com/milestones/#{milestone.number}"
    end

    test "GET /api/v3/repos/:owner/:repo/milestones returns an empty list", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones")

      assert json_response(conn, 200) == %{"milestones" => []}
    end
  end

  describe "create" do
    test "POST /api/v3/repos/:owner/:repo/milestones creates a milestone", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones", %{
          title: "v2.0",
          description: "Second release"
        })

      assert %{
               "title" => "v2.0",
               "description" => "Second release",
               "state" => "open",
               "number" => number
             } = json_response(conn, 201)

      assert Milestones.get_milestone_by_number!(number).title == "v2.0"
    end

    test "POST /api/v3/repos/:owner/:repo/milestones assigns sequential numbers", %{conn: conn} do
      first =
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones", %{title: "one"})

      second =
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones", %{title: "two"})

      assert json_response(second, 201)["number"] == json_response(first, 201)["number"] + 1
    end

    test "POST /api/v3/repos/:owner/:repo/milestones returns 422 without a title", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones", %{
          description: "No title"
        })

      assert %{"errors" => %{"title" => _}} = json_response(conn, 422)
      assert Milestones.list_milestones() == []
    end
  end

  describe "show" do
    test "GET /api/v3/repos/:owner/:repo/milestones/:milestone_number returns it", %{conn: conn} do
      milestone = milestone_fixture(%{title: "Show me"})

      conn =
        get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones/#{milestone.number}")

      assert %{"title" => "Show me", "id" => id} = json_response(conn, 200)
      assert id == milestone.id
    end

    test "GET /api/v3/repos/:owner/:repo/milestones/:milestone_number returns 404 when missing",
         %{conn: conn} do
      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones/999999")

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "update" do
    test "PATCH /api/v3/repos/:owner/:repo/milestones/:milestone_number closes it", %{conn: conn} do
      milestone = milestone_fixture(%{title: "Close me", state: "open"})

      conn =
        patch(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones/#{milestone.number}",
          %{
            state: "closed"
          }
        )

      assert json_response(conn, 200)["state"] == "closed"
      assert Milestones.get_milestone_by_number!(milestone.number).state == "closed"
    end

    test "PATCH /api/v3/repos/:owner/:repo/milestones/:milestone_number retitles it", %{
      conn: conn
    } do
      milestone = milestone_fixture(%{title: "Old title"})

      conn =
        patch(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones/#{milestone.number}",
          %{
            title: "New title"
          }
        )

      assert json_response(conn, 200)["title"] == "New title"
    end

    test "PATCH /api/v3/repos/:owner/:repo/milestones/:milestone_number returns 422 for a blank title",
         %{conn: conn} do
      milestone = milestone_fixture(%{title: "Keep me"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> patch(
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones/#{milestone.number}",
          ~s({"title": null})
        )

      assert %{"errors" => %{"title" => _}} = json_response(conn, 422)
      assert Milestones.get_milestone_by_number!(milestone.number).title == "Keep me"
    end

    test "PATCH /api/v3/repos/:owner/:repo/milestones/:milestone_number returns 404 when missing",
         %{conn: conn} do
      conn =
        patch(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones/999999", %{
          state: "closed"
        })

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "delete" do
    test "DELETE /api/v3/repos/:owner/:repo/milestones/:milestone_number returns 204", %{
      conn: conn
    } do
      milestone = milestone_fixture(%{title: "Delete me"})

      conn =
        delete(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones/#{milestone.number}"
        )

      assert response(conn, 204) == ""
      assert Milestones.list_milestones() == []
    end

    test "DELETE /api/v3/repos/:owner/:repo/milestones/:milestone_number returns 404 when missing",
         %{conn: conn} do
      conn = delete(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/milestones/999999")

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end
end
