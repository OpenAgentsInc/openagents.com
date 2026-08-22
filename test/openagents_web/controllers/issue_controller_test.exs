defmodule OpenAgentsWeb.IssueControllerTest do
  use OpenAgentsWeb.ConnCase

  setup %{conn: conn}, do: {:ok, conn: put_forge_api_token(conn, "issues", repository())}

  alias OpenAgents.Issues
  alias OpenAgents.Repositories

  describe "index" do
    test "GET /api/v3/repos/:owner/:repo/issues lists open issues by default", %{
      conn: conn
    } do
      {:ok, _issue} = Issues.create_issue(repository(), %{title: "First issue"})

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues")

      assert %{"issues" => [issue | _]} = json_response(conn, 200)
      assert issue["title"] == "First issue"
      assert issue["state"] == "open"
    end

    test "GET /api/v3/repos/:owner/:repo/issues filters by state", %{conn: conn} do
      {:ok, _open_issue} = Issues.create_issue(repository(), %{title: "Open issue"})

      {:ok, _closed_issue} =
        Issues.create_issue(repository(), %{title: "Closed issue", state: "closed"})

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?state=closed")

      assert %{"issues" => [issue]} = json_response(conn, 200)
      assert issue["title"] == "Closed issue"
      assert issue["state"] == "closed"
    end
  end

  describe "create" do
    test "POST /api/v3/repos/:owner/:repo/issues creates an issue", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues", %{
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
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues", %{body: "No title"})

      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "show" do
    test "GET /api/v3/repos/:owner/:repo/issues/:issue_number returns the issue", %{
      conn: conn
    } do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Show me"})

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      assert %{
               "title" => "Show me",
               "number" => n
             } = json_response(conn, 200)

      assert n == issue.number
    end

    test "GET /api/v3/repos/:owner/:repo/issues/:issue_number returns 404 when missing", %{
      conn: conn
    } do
      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/999999")

      assert json_response(conn, 404)
    end
  end

  describe "private repository reads" do
    test "a repository member can list and read issues, but an anonymous visitor cannot" do
      private_repository = repository_fixture(%{visibility: "private"})
      {:ok, issue} = Issues.create_issue(private_repository, %{title: "Private issue"})

      path =
        "/api/v3/repos/#{private_repository.owner}/#{private_repository.name}/issues"

      assert get(build_conn(), path) |> json_response(404)

      member_conn = put_forge_api_token(build_conn(), "private-issue-reader", private_repository)

      assert %{"issues" => [%{"title" => "Private issue"}]} =
               get(member_conn, path) |> json_response(200)

      issue_path = path <> "/#{issue.number}"

      member_conn = put_forge_api_token(build_conn(), "private-issue-show", private_repository)
      assert %{"title" => "Private issue"} = get(member_conn, issue_path) |> json_response(200)
      assert get(build_conn(), issue_path) |> json_response(404)
    end

    test "a bearer without repository membership cannot read private issues" do
      private_repository = repository_fixture(%{visibility: "private"})
      {:ok, _issue} = Issues.create_issue(private_repository, %{title: "Private issue"})

      conn = put_forge_api_token(build_conn(), "private-issue-nonmember")

      conn =
        get(
          conn,
          "/api/v3/repos/#{private_repository.owner}/#{private_repository.name}/issues"
        )

      assert json_response(conn, 404)
    end
  end

  describe "update" do
    test "PATCH /api/v3/repos/:owner/:repo/issues/:issue_number closes an issue", %{
      conn: conn
    } do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Close me"})

      conn =
        patch(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}", %{
          state: "closed"
        })

      assert %{"state" => "closed", "number" => n} = json_response(conn, 200)
      assert n == issue.number
    end
  end

  describe "request origin URLs" do
    test "issue URLs reflect the request host", %{conn: conn} do
      {:ok, _issue} = Issues.create_issue(repository(), %{title: "Origin issue"})

      conn =
        conn
        |> Map.replace!(:host, "staging.example.com")
        |> get(~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues")

      assert %{"issues" => [issue]} = json_response(conn, 200)

      assert issue["html_url"] =~
               "http://staging.example.com/OpenAgentsInc/openagents.com/issues/"
    end

    test "a forwarded host header does not replace the request origin", %{conn: conn} do
      {:ok, _issue} = Issues.create_issue(repository(), %{title: "Forwarded issue"})

      conn =
        conn
        |> put_req_header("x-forwarded-host", "evil.example.net")
        |> get(~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues")

      assert %{"issues" => [issue]} = json_response(conn, 200)
      refute issue["html_url"] =~ "evil.example.net"
    end
  end

  defp repository do
    Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
