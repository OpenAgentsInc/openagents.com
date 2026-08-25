defmodule OpenAgentsWeb.IssueDependencyControllerTest do
  use OpenAgentsWeb.ConnCase

  alias OpenAgents.Issues
  alias OpenAgents.Repositories

  setup %{conn: conn}, do: {:ok, conn: put_forge_api_token(conn, "dependencies", repository())}

  describe "create" do
    test "POST records prerequisites and answers with the resulting graph", %{conn: conn} do
      {:ok, blocked} = Issues.create_issue(repository(), %{title: "Aim agents at the backlog"})
      {:ok, blocker} = Issues.create_issue(repository(), %{title: "Deliver the work system"})

      conn = post(conn, dependencies_path(blocked), %{blocked_by: [blocker.number]})

      assert %{
               "blocked" => true,
               "blocked_by" => [
                 %{
                   "number" => number,
                   "title" => "Deliver the work system",
                   "state" => "open"
                 }
               ],
               "blocks" => []
             } = json_response(conn, 201)

      assert number == blocker.number
    end

    test "POST refuses a prerequisite that does not exist", %{conn: conn} do
      {:ok, blocked} = Issues.create_issue(repository(), %{title: "Waiting"})

      conn = post(conn, dependencies_path(blocked), %{blocked_by: [999_999]})

      assert %{"errors" => %{"blocked_by" => [message]}} = json_response(conn, 422)
      assert message =~ "does not exist in this repository"
    end

    test "POST refuses a self reference", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Alone"})

      conn = post(conn, dependencies_path(issue), %{blocked_by: [issue.number]})

      assert %{"errors" => %{"blocked_by" => [message]}} = json_response(conn, 422)
      assert message =~ "cannot be a prerequisite of itself"
    end

    test "POST refuses an edge that would close a cycle", %{conn: conn} do
      {:ok, first} = Issues.create_issue(repository(), %{title: "First"})
      {:ok, second} = Issues.create_issue(repository(), %{title: "Second"})
      assert :ok = Issues.add_dependencies(second, [first.number])

      conn = post(conn, dependencies_path(first), %{blocked_by: [second.number]})

      assert %{"errors" => %{"blocked_by" => [message]}} = json_response(conn, 422)
      assert message =~ "Would create a dependency cycle"
    end

    test "POST refuses a body without a list of numbers", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Waiting"})

      conn = post(conn, dependencies_path(issue), %{blocked_by: "12"})

      assert %{"errors" => %{"blocked_by" => [message]}} = json_response(conn, 422)
      assert message =~ "must be a list of issue numbers"
    end

    test "POST answers 404 for an issue that does not exist", %{conn: conn} do
      conn =
        post(
          conn,
          "/api/v1/repos/OpenAgentsInc/openagents.com/issues/999999/dependencies",
          %{blocked_by: []}
        )

      assert json_response(conn, 404)
    end
  end

  describe "index" do
    test "GET reads both directions of the graph", %{conn: conn} do
      {:ok, blocked} = Issues.create_issue(repository(), %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository(), %{title: "Prerequisite"})
      assert :ok = Issues.add_dependencies(blocked, [blocker.number])

      assert %{"blocked" => true, "blocked_by" => [_one], "blocks" => []} =
               get(conn, dependencies_path(blocked)) |> json_response(200)

      assert %{"blocked" => false, "blocked_by" => [], "blocks" => [_one]} =
               get(conn, dependencies_path(blocker)) |> json_response(200)
    end

    test "GET reports an issue with no prerequisites as unblocked", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Ready"})

      assert %{"blocked" => false, "blocked_by" => [], "blocks" => []} =
               get(conn, dependencies_path(issue)) |> json_response(200)
    end
  end

  describe "delete" do
    test "DELETE removes one prerequisite", %{conn: conn} do
      {:ok, blocked} = Issues.create_issue(repository(), %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository(), %{title: "Prerequisite"})
      assert :ok = Issues.add_dependencies(blocked, [blocker.number])

      conn = delete(conn, dependencies_path(blocked) <> "/#{blocker.number}")

      assert %{"blocked" => false, "blocked_by" => []} = json_response(conn, 200)
    end

    test "DELETE answers 404 when the edge is not recorded", %{conn: conn} do
      {:ok, blocked} = Issues.create_issue(repository(), %{title: "Waiting"})
      {:ok, other} = Issues.create_issue(repository(), %{title: "Unrelated"})

      conn = delete(conn, dependencies_path(blocked) <> "/#{other.number}")

      assert %{"message" => message} = json_response(conn, 404)
      assert message =~ "is not a prerequisite of this issue"
    end
  end

  describe "authorization" do
    test "an anonymous visitor cannot read the graph of a private repository" do
      private_repository = repository_fixture(%{visibility: "private"})
      {:ok, issue} = Issues.create_issue(private_repository, %{title: "Private"})

      path =
        "/api/v1/repos/#{private_repository.owner}/#{private_repository.name}" <>
          "/issues/#{issue.number}/dependencies"

      assert get(build_conn(), path) |> json_response(404)

      member_conn = put_forge_api_token(build_conn(), "private-graph", private_repository)
      assert %{"blocked" => false} = get(member_conn, path) |> json_response(200)
    end

    test "a bearer without write access cannot record a prerequisite" do
      other_repository = repository_fixture()
      {:ok, blocked} = Issues.create_issue(other_repository, %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(other_repository, %{title: "Prerequisite"})

      conn = put_forge_api_token(build_conn(), "dependency-nonmember")

      path =
        "/api/v1/repos/#{other_repository.owner}/#{other_repository.name}" <>
          "/issues/#{blocked.number}/dependencies"

      assert post(conn, path, %{blocked_by: [blocker.number]}) |> json_response(404)
      assert %{blocked_by: []} = Issues.dependencies(blocked)
    end

    test "an anonymous visitor cannot record a prerequisite" do
      {:ok, blocked} = Issues.create_issue(repository(), %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository(), %{title: "Prerequisite"})

      conn = post(build_conn(), dependencies_path(blocked), %{blocked_by: [blocker.number]})

      assert conn.status in [401, 404]
      assert %{blocked_by: []} = Issues.dependencies(blocked)
    end
  end

  defp dependencies_path(issue) do
    "/api/v1/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/dependencies"
  end

  defp repository do
    Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
