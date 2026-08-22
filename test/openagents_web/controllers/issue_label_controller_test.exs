defmodule OpenAgentsWeb.IssueLabelControllerTest do
  use OpenAgentsWeb.ConnCase

  setup %{conn: conn}, do: {:ok, conn: put_forge_api_token(conn, "issue-labels", repository())}

  import OpenAgents.LabelsFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Labels

  setup do
    {:ok, issue} = Issues.create_issue(repository(), %{title: "Labelled issue"})
    %{issue: issue}
  end

  describe "index" do
    test "GET .../issues/:issue_number/labels returns an empty list for a fresh issue", %{
      conn: conn,
      issue: issue
    } do
      conn =
        get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/labels")

      assert json_response(conn, 200) == %{"labels" => []}
    end

    test "GET .../issues/:issue_number/labels lists labels already on the issue", %{
      conn: conn,
      issue: issue
    } do
      label_fixture(repository(), %{name: "bug", color: "d73a4a"})
      {:ok, _issue} = Issues.add_labels(issue, ["bug"])

      conn =
        get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/labels")

      assert %{"labels" => [label]} = json_response(conn, 200)
      assert label["name"] == "bug"
    end

    test "GET .../issues/:issue_number/labels returns 404 for a missing issue", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/999999/labels")

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "create" do
    test "POST .../issues/:issue_number/labels adds a label to the issue", %{
      conn: conn,
      issue: issue
    } do
      label_fixture(repository(), %{name: "bug", color: "d73a4a"})

      conn =
        post(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/labels",
          %{
            labels: ["bug"]
          }
        )

      assert %{"labels" => [label]} = json_response(conn, 200)
      assert label["name"] == "bug"

      assert [%{"name" => "bug"}] = Issues.get_issue_by_number!(repository(), issue.number).labels
    end

    test "POST .../issues/:issue_number/labels adds several labels at once", %{
      conn: conn,
      issue: issue
    } do
      label_fixture(repository(), %{name: "bug", color: "d73a4a"})
      label_fixture(repository(), %{name: "docs", color: "0075ca"})

      conn =
        post(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/labels",
          %{
            labels: ["bug", "docs"]
          }
        )

      assert %{"labels" => labels} = json_response(conn, 200)
      assert Enum.map(labels, & &1["name"]) == ["bug", "docs"]
    end

    test "POST .../issues/:issue_number/labels does not duplicate an existing label", %{
      conn: conn,
      issue: issue
    } do
      label_fixture(repository(), %{name: "bug", color: "d73a4a"})
      {:ok, _issue} = Issues.add_labels(issue, ["bug"])

      conn =
        post(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/labels",
          %{
            labels: ["bug"]
          }
        )

      assert %{"labels" => [_only_one]} = json_response(conn, 200)
    end

    test "POST .../issues/:issue_number/labels with no labels leaves the issue unchanged", %{
      conn: conn,
      issue: issue
    } do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/labels",
          %{}
        )

      assert json_response(conn, 200) == %{"labels" => []}
    end

    # GitHub creates a missing label on the fly when one is added to an
    # issue, so a script that references `perf` before anyone defined it
    # still works and the label outlives the call.
    test "POST .../issues/:issue_number/labels creates a label that does not exist yet", %{
      conn: conn,
      issue: issue
    } do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/labels",
          %{
            labels: ["never-created"]
          }
        )

      assert %{"labels" => [%{"name" => "never-created"}]} = json_response(conn, 200)

      assert [%{"name" => "never-created"}] =
               Issues.get_issue_by_number!(repository(), issue.number).labels

      refute Labels.get_label_by_name!(
               OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com"),
               "never-created"
             ).color == ""
    end

    test "POST .../issues/:issue_number/labels rejects an empty label without crashing", %{
      conn: conn,
      issue: issue
    } do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/labels",
          %{labels: [""]}
        )

      assert %{"errors" => %{"name" => [_message]}} = json_response(conn, 422)
      assert Issues.get_issue_by_number!(repository(), issue.number).labels == []
    end

    test "POST .../issues/:issue_number/labels returns 404 for a missing issue", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/999999/labels", %{
          labels: ["bug"]
        })

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "delete" do
    test "DELETE .../issues/:issue_number/labels/:name removes the label", %{
      conn: conn,
      issue: issue
    } do
      label_fixture(repository(), %{name: "bug", color: "d73a4a"})
      label_fixture(repository(), %{name: "docs", color: "0075ca"})
      {:ok, _issue} = Issues.add_labels(issue, ["bug", "docs"])

      conn =
        delete(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/labels/bug"
        )

      assert %{"labels" => [label]} = json_response(conn, 200)
      assert label["name"] == "docs"

      assert [%{"name" => "docs"}] =
               Issues.get_issue_by_number!(repository(), issue.number).labels
    end

    test "DELETE .../issues/:issue_number/labels/:name decodes an escaped name", %{
      conn: conn,
      issue: issue
    } do
      label_fixture(repository(), %{name: "good first issue", color: "7057ff"})
      {:ok, _issue} = Issues.add_labels(issue, ["good first issue"])

      conn =
        delete(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/labels/good first issue"
        )

      assert json_response(conn, 200) == %{"labels" => []}
    end

    # GitHub refuses the removal rather than pretending it happened, so a
    # script whose bookkeeping drifted learns about it instead of silently
    # succeeding.
    test "DELETE .../issues/:issue_number/labels/:name returns 404 for an unattached label", %{
      conn: conn,
      issue: issue
    } do
      label_fixture(repository(), %{name: "bug", color: "d73a4a"})
      {:ok, _issue} = Issues.add_labels(issue, ["bug"])

      conn =
        delete(
          conn,
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}/labels/docs"
        )

      assert json_response(conn, 404)
      assert [%{"name" => "bug"}] = Issues.get_issue_by_number!(repository(), issue.number).labels
    end

    test "DELETE .../issues/:issue_number/labels/:name returns 404 for a missing issue", %{
      conn: conn
    } do
      conn = delete(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/999999/labels/bug")

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  defp repository do
    OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
