defmodule OpenAgentsWeb.LabelControllerTest do
  use OpenAgentsWeb.ConnCase

  setup %{conn: conn}, do: {:ok, conn: put_forge_api_token(conn, "labels", repository())}

  import OpenAgents.LabelsFixtures

  alias OpenAgents.Labels

  describe "index" do
    test "GET /api/v1/repos/:owner/:repo/labels lists labels", %{conn: conn} do
      label_fixture(repository(), %{name: "bug", color: "d73a4a"})

      conn = get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels")

      assert %{"labels" => [label]} = json_response(conn, 200)
      assert label["name"] == "bug"
      assert label["color"] == "d73a4a"
    end

    test "GET /api/v1/repos/:owner/:repo/labels renders a repo-scoped url", %{conn: conn} do
      label_fixture(repository(), %{name: "bug", color: "d73a4a"})

      conn = get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels")

      assert %{"labels" => [label]} = json_response(conn, 200)

      assert label["url"] ==
               "http://www.example.com/api/v1/repos/OpenAgentsInc/openagents.com/labels/bug"
    end

    test "GET /api/v1/repos/:owner/:repo/labels returns an empty list", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels")

      assert json_response(conn, 200) == %{"labels" => []}
    end
  end

  describe "create" do
    test "POST /api/v1/repos/:owner/:repo/labels creates a label", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels", %{
          name: "enhancement",
          color: "a2eeef",
          description: "New feature"
        })

      assert %{
               "name" => "enhancement",
               "color" => "a2eeef",
               "description" => "New feature",
               "default" => false
             } = json_response(conn, 201)

      assert Labels.get_label_by_name!(repository(), "enhancement").color == "a2eeef"
    end

    test "POST /api/v1/repos/:owner/:repo/labels returns 422 without a color", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels", %{name: "no-color"})

      assert %{"errors" => %{"color" => _}} = json_response(conn, 422)
    end

    test "POST /api/v1/repos/:owner/:repo/labels returns 422 without a name", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels", %{color: "ffffff"})

      assert %{"errors" => %{"name" => _}} = json_response(conn, 422)
    end

    test "POST /api/v1/repos/:owner/:repo/labels does not persist owner or repo", %{conn: conn} do
      post(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels", %{
        name: "scoped",
        color: "ffffff"
      })

      label = Labels.get_label_by_name!(repository(), "scoped")
      refute Map.has_key?(label, :owner)
      refute Map.has_key?(label, :repo)
    end
  end

  describe "show" do
    test "GET /api/v1/repos/:owner/:repo/labels/:name returns the label", %{conn: conn} do
      label = label_fixture(repository(), %{name: "bug", color: "d73a4a"})

      conn = get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels/bug")

      assert %{"name" => "bug", "id" => id} = json_response(conn, 200)
      assert id == label.id
    end

    test "GET /api/v1/repos/:owner/:repo/labels/:name decodes an escaped name", %{conn: conn} do
      label_fixture(repository(), %{name: "good first issue", color: "7057ff"})

      conn = get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels/good first issue")

      assert json_response(conn, 200)["name"] == "good first issue"
    end

    test "GET /api/v1/repos/:owner/:repo/labels/:name returns 404 when missing", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels/nope")

      assert_api_error(conn, 404, "not_found")
    end

    # The advertised URL is percent-encoded the way a path is, so a label
    # with a space in its name advertises a link that resolves.
    test "the rendered url round-trips through the show endpoint", %{conn: conn} do
      label_fixture(repository(), %{name: "good first issue", color: "7057ff"})

      conn = get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels")

      assert %{"labels" => [label]} = json_response(conn, 200)
      assert label["url"] =~ "good%20first%20issue"

      %URI{path: path} = URI.parse(label["url"])
      assert get(conn, path).resp_body =~ "good first issue"
    end
  end

  describe "update" do
    test "PATCH /api/v1/repos/:owner/:repo/labels/:name updates the color", %{conn: conn} do
      label_fixture(repository(), %{name: "bug", color: "d73a4a"})

      conn =
        patch(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels/bug", %{color: "000000"})

      assert %{"name" => "bug", "color" => "000000"} = json_response(conn, 200)
      assert Labels.get_label_by_name!(repository(), "bug").color == "000000"
    end

    test "PATCH /api/v1/repos/:owner/:repo/labels/:name updates the description", %{conn: conn} do
      label_fixture(repository(), %{name: "bug", color: "d73a4a", description: "old"})

      conn =
        patch(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels/bug", %{
          description: "new"
        })

      assert json_response(conn, 200)["description"] == "new"
    end

    # GitHub renames through `new_name`; the name in the path identifies the
    # label and `new_name` is what it becomes.
    test "PATCH /api/v1/repos/:owner/:repo/labels/:name renames with new_name", %{conn: conn} do
      label_fixture(repository(), %{name: "bug", color: "d73a4a"})

      conn =
        patch(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels/bug", %{
          new_name: "defect"
        })

      assert json_response(conn, 200)["name"] == "defect"
      assert Labels.get_label_by_name!(repository(), "defect").color == "d73a4a"

      assert_raise Ecto.NoResultsError, fn -> Labels.get_label_by_name!(repository(), "bug") end
    end

    test "PATCH /api/v1/repos/:owner/:repo/labels/:name returns 422 for a blank color", %{
      conn: conn
    } do
      label_fixture(repository(), %{name: "bug", color: "d73a4a"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> patch(~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels/bug", ~s({"color": null}))

      assert %{"errors" => %{"color" => _}} = json_response(conn, 422)
      assert Labels.get_label_by_name!(repository(), "bug").color == "d73a4a"
    end

    test "PATCH /api/v1/repos/:owner/:repo/labels/:name returns 404 when missing", %{conn: conn} do
      conn =
        patch(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels/nope", %{color: "000000"})

      assert_api_error(conn, 404, "not_found")
    end
  end

  describe "delete" do
    test "DELETE /api/v1/repos/:owner/:repo/labels/:name returns 204", %{conn: conn} do
      label_fixture(repository(), %{name: "bug", color: "d73a4a"})

      conn = delete(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels/bug")

      assert response(conn, 204) == ""
      assert Labels.list_labels(repository()) == []
    end

    test "DELETE /api/v1/repos/:owner/:repo/labels/:name returns 404 when missing", %{conn: conn} do
      conn = delete(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/labels/nope")

      assert_api_error(conn, 404, "not_found")
    end
  end

  defp repository do
    OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
