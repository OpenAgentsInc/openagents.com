defmodule OpenAgentsWeb.ProjectControllerTest do
  use OpenAgentsWeb.ConnCase

  setup %{conn: conn}, do: {:ok, conn: put_forge_api_token(conn, "projects", "alice")}

  import OpenAgents.ProjectFieldsFixtures
  import OpenAgents.ProjectItemsFixtures
  import OpenAgents.ProjectsFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Projects

  describe "index" do
    test "GET /api/v3/users/:username/projectsV2 lists that user's projects", %{conn: conn} do
      project_fixture(%{title: "Roadmap", owner: "alice", state: "open"})

      conn = get(conn, ~p"/api/v3/users/alice/projectsV2")

      assert %{"projects" => [project]} = json_response(conn, 200)
      assert project["title"] == "Roadmap"
      assert project["owner"] == "alice"
      assert project["state"] == "open"
    end

    test "GET /api/v3/users/:username/projectsV2 excludes other owners' projects", %{conn: conn} do
      project_fixture(%{title: "Mine", owner: "alice"})
      project_fixture(%{title: "Theirs", owner: "bob"})

      conn = get(conn, ~p"/api/v3/users/alice/projectsV2")

      assert %{"projects" => [%{"title" => "Mine"}]} = json_response(conn, 200)
    end

    test "GET /api/v3/users/:username/projectsV2 returns an empty list for an unknown user", %{
      conn: conn
    } do
      conn = get(conn, ~p"/api/v3/users/nobody/projectsV2")

      assert json_response(conn, 200) == %{"projects" => []}
    end
  end

  describe "create" do
    test "POST /api/v3/:owner/projectsV2 creates a project", %{conn: conn} do
      conn = post(conn, ~p"/api/v3/alice/projectsV2", %{title: "New board"})

      assert %{"title" => "New board", "owner" => "alice", "number" => number} =
               json_response(conn, 201)

      assert Projects.get_project_by_number!(number).title == "New board"
    end

    test "POST /api/v3/:owner/projectsV2 takes the owner from the path", %{conn: conn} do
      conn = post(conn, ~p"/api/v3/alice/projectsV2", %{title: "Board", owner: "mallory"})

      assert json_response(conn, 201)["owner"] == "alice"
    end

    test "POST /api/v3/:owner/projectsV2 returns 422 without a title", %{conn: conn} do
      conn = post(conn, ~p"/api/v3/alice/projectsV2", %{})

      assert %{"errors" => %{"title" => _}} = json_response(conn, 422)
      assert Projects.list_projects() == []
    end
  end

  describe "show" do
    test "GET /api/v3/users/:username/projectsV2/:project_number returns the project", %{
      conn: conn
    } do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn = get(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}")

      assert %{"title" => "Roadmap", "id" => id} = json_response(conn, 200)
      assert id == project.id
    end

    test "GET /api/v3/users/:username/projectsV2/:project_number returns 404 when missing", %{
      conn: conn
    } do
      conn = get(conn, ~p"/api/v3/users/alice/projectsV2/999999")

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "items" do
    test "GET .../projectsV2/:project_number/items returns an empty list for a new project", %{
      conn: conn
    } do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn = get(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/items")

      assert json_response(conn, 200) == %{"items" => []}
    end

    test "GET .../projectsV2/:project_number/items lists the project's items", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})
      item = project_item_fixture(%{project_id: project.id, values: %{"Status" => "Todo"}})

      conn = get(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/items")

      assert %{"items" => [rendered]} = json_response(conn, 200)
      assert rendered["id"] == item.id
      assert rendered["issue_id"] == item.issue_id
      assert rendered["values"] == %{"Status" => "Todo"}
    end

    test "GET .../projectsV2/:project_number/items returns 404 for a missing project", %{
      conn: conn
    } do
      conn = get(conn, ~p"/api/v3/users/alice/projectsV2/999999/items")

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "create_item" do
    setup do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})
      {:ok, issue} = Issues.create_issue(%{title: "Trackable issue"})
      %{project: project, issue: issue}
    end

    test "POST .../projectsV2/:project_number/items adds an issue to the board", %{
      conn: conn,
      project: project,
      issue: issue
    } do
      conn =
        post(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/items", %{
          issue_number: issue.number
        })

      assert %{"items" => [item]} = json_response(conn, 201)
      assert item["issue_id"] == issue.id

      assert [%{issue_id: issue_id}] = Projects.list_project_items(project.id)
      assert issue_id == issue.id
    end

    test "POST .../projectsV2/:project_number/items stores field values", %{
      conn: conn,
      project: project,
      issue: issue
    } do
      conn =
        post(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/items", %{
          issue_number: issue.number,
          values: %{"Status" => "In Progress"}
        })

      assert %{"items" => [%{"values" => %{"Status" => "In Progress"}}]} =
               json_response(conn, 201)
    end

    test "POST .../projectsV2/:project_number/items returns 422 for non-map values", %{
      conn: conn,
      project: project,
      issue: issue
    } do
      conn =
        post(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/items", %{
          issue_number: issue.number,
          values: "not-a-map"
        })

      assert %{"errors" => %{"values" => _}} = json_response(conn, 422)
      assert Projects.list_project_items(project.id) == []
    end

    test "POST .../projectsV2/:project_number/items returns 422 without an issue_number", %{
      conn: conn,
      project: project
    } do
      conn = post(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/items", %{})

      assert %{"errors" => %{"issue_number" => _}} = json_response(conn, 422)
      assert Projects.list_project_items(project.id) == []
    end

    test "POST .../projectsV2/:project_number/items returns 422 for a non-numeric issue_number",
         %{conn: conn, project: project} do
      conn =
        post(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/items", %{
          issue_number: "not-a-number"
        })

      assert %{"errors" => %{"issue_number" => _}} = json_response(conn, 422)
      assert Projects.list_project_items(project.id) == []
    end

    test "POST .../projectsV2/:project_number/items returns 404 for an unknown issue", %{
      conn: conn,
      project: project
    } do
      conn =
        post(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/items", %{
          issue_number: 999_999
        })

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end

    test "POST .../projectsV2/:project_number/items returns 404 for a missing project", %{
      conn: conn,
      issue: issue
    } do
      conn =
        post(conn, ~p"/api/v3/users/alice/projectsV2/999999/items", %{issue_number: issue.number})

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "update_item" do
    setup do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})
      item = project_item_fixture(%{project_id: project.id, values: %{"Status" => "Todo"}})
      %{project: project, item: item}
    end

    test "PATCH .../items/:item_id merges new field values", %{
      conn: conn,
      project: project,
      item: item
    } do
      conn =
        patch(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/items/#{item.id}", %{
          values: %{"Status" => "Done"}
        })

      assert %{"items" => [%{"values" => %{"Status" => "Done"}}]} = json_response(conn, 200)
      assert Projects.get_project_item!(item.id).values == %{"Status" => "Done"}
    end

    test "PATCH .../items/:item_id keeps values it was not asked to change", %{
      conn: conn,
      project: project,
      item: item
    } do
      conn =
        patch(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/items/#{item.id}", %{
          values: %{"Priority" => "P1"}
        })

      assert %{"items" => [%{"values" => values}]} = json_response(conn, 200)
      assert values == %{"Status" => "Todo", "Priority" => "P1"}
    end

    test "PATCH .../items/:item_id returns 422 for non-map values", %{
      conn: conn,
      project: project,
      item: item
    } do
      conn =
        patch(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/items/#{item.id}", %{
          values: "not-a-map"
        })

      assert %{"errors" => %{"values" => _}} = json_response(conn, 422)
      assert Projects.get_project_item!(item.id).values == %{"Status" => "Todo"}
    end

    test "PATCH .../items/:item_id returns 404 for a missing item", %{
      conn: conn,
      project: project
    } do
      conn =
        patch(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/items/999999", %{
          values: %{"Status" => "Done"}
        })

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "fields" do
    test "GET .../projectsV2/:project_number/fields returns an empty list for a new project", %{
      conn: conn
    } do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn = get(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/fields")

      assert json_response(conn, 200) == %{"fields" => []}
    end

    test "GET .../projectsV2/:project_number/fields lists the project's fields", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      field =
        project_field_fixture(%{
          project_id: project.id,
          name: "Status",
          data_type: "single_select",
          options: %{"values" => ["Todo", "Done"]}
        })

      conn = get(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/fields")

      assert %{"fields" => [rendered]} = json_response(conn, 200)
      assert rendered["id"] == field.id
      assert rendered["name"] == "Status"
      assert rendered["data_type"] == "single_select"
      assert rendered["options"] == %{"values" => ["Todo", "Done"]}
    end

    test "GET .../projectsV2/:project_number/fields returns 404 for a missing project", %{
      conn: conn
    } do
      conn = get(conn, ~p"/api/v3/users/alice/projectsV2/999999/fields")

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end

    test "POST .../projectsV2/:project_number/fields creates a field", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn =
        post(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/fields", %{
          name: "Status",
          data_type: "single_select",
          options: %{values: ["To Do", "In Progress", "Done"]}
        })

      assert %{
               "fields" => [
                 %{
                   "name" => "Status",
                   "data_type" => "single_select",
                   "options" => %{"values" => ["To Do", "In Progress", "Done"]}
                 }
               ]
             } = json_response(conn, 201)

      assert [%{name: "Status", project_id: project_id}] = Projects.list_project_fields(project)
      assert project_id == project.id
    end

    test "POST .../projectsV2/:project_number/fields returns 422 without required values", %{
      conn: conn
    } do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn = post(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/fields", %{})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "name")
      assert Map.has_key?(errors, "data_type")
      assert Projects.list_project_fields(project) == []
    end

    test "POST .../projectsV2/:project_number/fields takes the project from the path", %{
      conn: conn
    } do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})
      other_project = project_fixture(%{title: "Other", owner: "alice"})

      conn =
        post(conn, ~p"/api/v3/users/alice/projectsV2/#{project.number}/fields", %{
          name: "Status",
          data_type: "single_select",
          project_id: other_project.id
        })

      assert json_response(conn, 201)
      assert [%{project_id: project_id}] = Projects.list_project_fields(project)
      assert project_id == project.id
      assert Projects.list_project_fields(other_project) == []
    end
  end

  describe "owner-path authorization" do
    test "another username cannot read or mutate a project through any project action", %{
      conn: conn
    } do
      project = project_fixture(%{title: "Alice only", owner: "alice"})
      {:ok, issue} = Issues.create_issue(%{title: "Tracked"})

      {:ok, item} =
        Projects.create_project_item(%{"issue_number" => issue.number}, project)

      _field =
        project_field_fixture(%{
          project_id: project.id,
          name: "Status",
          data_type: "single_select"
        })

      assert get(conn, ~p"/api/v3/users/bob/projectsV2/#{project.number}")
             |> json_response(404) == %{"message" => "Not Found"}

      assert get(recycle(conn), ~p"/api/v3/users/bob/projectsV2/#{project.number}/items")
             |> json_response(404) == %{"message" => "Not Found"}

      assert get(recycle(conn), ~p"/api/v3/users/bob/projectsV2/#{project.number}/fields")
             |> json_response(404) == %{"message" => "Not Found"}

      assert post(
               recycle(conn),
               ~p"/api/v3/users/bob/projectsV2/#{project.number}/items",
               %{issue_number: issue.number}
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert patch(
               recycle(conn),
               ~p"/api/v3/users/bob/projectsV2/#{project.number}/items/#{item.id}",
               %{values: %{"Status" => "Done"}}
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert post(
               recycle(conn),
               ~p"/api/v3/users/bob/projectsV2/#{project.number}/fields",
               %{name: "Priority", data_type: "single_select"}
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert Projects.get_project_item!(item.id).values == %{}
    end

    test "a token owner cannot create a project for another username", %{conn: conn} do
      assert post(conn, ~p"/api/v3/bob/projectsV2", %{title: "Not Bob's"})
             |> json_response(404) == %{"message" => "Not Found"}

      assert Projects.list_projects() == []
    end
  end
end
