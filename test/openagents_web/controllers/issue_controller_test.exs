defmodule OpenAgentsWeb.IssueControllerTest do
  use OpenAgentsWeb.ConnCase

  setup %{conn: conn}, do: {:ok, conn: put_forge_api_token(conn, "issues")}

  alias OpenAgents.Issues

  describe "index" do
    test "GET /api/v3/repos/:owner/:repo/issues lists open issues by default", %{
      conn: conn
    } do
      {:ok, _issue} = Issues.create_issue(%{title: "First issue"})

      conn = get(conn, ~p"/api/v3/repos/OpenAgents/openagents/issues")

      assert %{"issues" => [issue | _]} = json_response(conn, 200)
      assert issue["title"] == "First issue"
      assert issue["state"] == "open"
    end

    test "GET /api/v3/repos/:owner/:repo/issues filters by state", %{conn: conn} do
      {:ok, _open_issue} = Issues.create_issue(%{title: "Open issue"})
      {:ok, _closed_issue} = Issues.create_issue(%{title: "Closed issue", state: "closed"})

      conn = get(conn, ~p"/api/v3/repos/OpenAgents/openagents/issues?state=closed")

      assert %{"issues" => [issue]} = json_response(conn, 200)
      assert issue["title"] == "Closed issue"
      assert issue["state"] == "closed"
    end
  end

  describe "create" do
    test "POST /api/v3/repos/:owner/:repo/issues creates an issue", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v3/repos/OpenAgents/openagents/issues", %{
          title: "New issue",
          body: "A description"
        })

      assert %{
               "number" => _,
               "title" => "New issue",
               "body" => "A description",
               "state" => "open"
             } = json_response(conn, 201)
    end

    test "POST /api/v3/repos/:owner/:repo/issues returns 422 for missing title", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v3/repos/OpenAgents/openagents/issues", %{body: "No title"})

      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "show" do
    test "GET /api/v3/repos/:owner/:repo/issues/:issue_number returns the issue", %{
      conn: conn
    } do
      {:ok, issue} = Issues.create_issue(%{title: "Show me"})

      conn = get(conn, ~p"/api/v3/repos/OpenAgents/openagents/issues/#{issue.number}")

      assert %{
               "title" => "Show me",
               "number" => n
             } = json_response(conn, 200)

      assert n == issue.number
    end

    test "GET /api/v3/repos/:owner/:repo/issues/:issue_number returns 404 when missing", %{
      conn: conn
    } do
      conn = get(conn, ~p"/api/v3/repos/OpenAgents/openagents/issues/999999")

      assert json_response(conn, 404)
    end
  end

  describe "update" do
    test "PATCH /api/v3/repos/:owner/:repo/issues/:issue_number closes an issue", %{
      conn: conn
    } do
      {:ok, issue} = Issues.create_issue(%{title: "Close me"})

      conn =
        patch(conn, ~p"/api/v3/repos/OpenAgents/openagents/issues/#{issue.number}", %{
          state: "closed"
        })

      assert %{"state" => "closed", "number" => n} = json_response(conn, 200)
      assert n == issue.number
    end
  end
end
