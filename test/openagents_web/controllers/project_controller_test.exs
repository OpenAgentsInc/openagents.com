defmodule OpenAgentsWeb.ProjectControllerTest do
  use OpenAgentsWeb.ConnCase

  alias OpenAgents.Issues
  alias OpenAgents.Projects

  @owner "ProjectTestOrg"
  @repo "project-api"

  setup %{conn: conn} do
    user = github_user("api-token-projects", "alice")

    repository =
      repository_with_member_fixture(user, %{
        owner: @owner,
        name: @repo,
        visibility: "private"
      })

    Process.put({__MODULE__, :repository}, repository)
    on_exit(fn -> Process.delete({__MODULE__, :repository}) end)

    {:ok,
     conn: put_forge_api_token(conn, "projects", "alice"), repository: repository, user: user}
  end

  describe "index" do
    test "GET /api/v3/repos/:owner/:repo/projectsV2 lists the repository's projects", %{
      conn: conn
    } do
      project_fixture(%{title: "Roadmap", owner: "alice", state: "open"})

      conn = get(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2")

      assert %{"projects" => [project]} = json_response(conn, 200)
      assert project["title"] == "Roadmap"
      assert project["owner"] == "alice"
      assert project["state"] == "open"
    end

    test "GET /api/v3/repos/:owner/:repo/projectsV2 excludes another repository", %{conn: conn} do
      project_fixture(%{title: "Mine", owner: "alice"})
      other_repository = repository_fixture(%{owner: "Elsewhere", name: "other-projects"})

      {:ok, _project} =
        Projects.create_project(other_repository, %{title: "Theirs", owner: "bob"})

      conn = get(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2")

      assert %{"projects" => [%{"title" => "Mine"}]} = json_response(conn, 200)
    end

    test "GET /api/v3/repos/:owner/:repo/projectsV2 hides a private repository from a non-member" do
      conn = get(build_conn(), ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2")
      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "create" do
    test "POST /api/v3/repos/:owner/:repo/projectsV2 creates a project", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2", %{
          title: "New board"
        })

      assert %{"title" => "New board", "owner" => "alice", "number" => number} =
               json_response(conn, 201)

      assert Projects.get_project_by_number!(repository(), number).title == "New board"
    end

    test "POST /api/v3/repos/:owner/:repo/projectsV2 ignores repository override params", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2", %{
          title: "Board",
          owner: "mallory",
          repo: "elsewhere"
        })

      assert json_response(conn, 201)["owner"] == "alice"
    end

    test "POST /api/v3/repos/:owner/:repo/projectsV2 returns 422 without a title", %{
      conn: conn
    } do
      conn = post(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2", %{})

      assert %{"errors" => %{"title" => _}} = json_response(conn, 422)
      assert Projects.list_projects(repository()) == []
    end
  end

  describe "show" do
    test "GET /api/v3/repos/:owner/:repo/projectsV2/:project_number returns the project", %{
      conn: conn
    } do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn = get(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}")

      assert %{"title" => "Roadmap", "id" => id} = json_response(conn, 200)
      assert id == project.id
    end

    test "GET /api/v3/repos/:owner/:repo/projectsV2/:project_number returns 404 when missing", %{
      conn: conn
    } do
      conn = get(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/999999")

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "items" do
    test "GET .../projectsV2/:project_number/items returns an empty list for a new project", %{
      conn: conn
    } do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn =
        get(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items")

      assert json_response(conn, 200) == %{"items" => []}
    end

    test "GET .../projectsV2/:project_number/items lists the project's items", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})
      item = project_item_fixture(%{project_id: project.id, values: %{"Status" => "Todo"}})

      conn =
        get(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items")

      assert %{"items" => [rendered]} = json_response(conn, 200)
      assert rendered["id"] == item.id
      assert rendered["issue_id"] == item.issue_id
      assert rendered["values"] == %{"Status" => "Todo"}
    end

    test "GET .../projectsV2/:project_number/items returns 404 for a missing project", %{
      conn: conn
    } do
      conn = get(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/999999/items")

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "create_item" do
    setup do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})
      {:ok, issue} = create_issue(%{title: "Trackable issue"})
      %{project: project, issue: issue}
    end

    test "POST .../projectsV2/:project_number/items adds an issue to the board", %{
      conn: conn,
      project: project,
      issue: issue
    } do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{
            issue_number: issue.number
          }
        )

      assert %{"items" => [item]} = json_response(conn, 201)
      assert item["issue_id"] == issue.id

      assert [%{issue_id: issue_id}] = Projects.list_project_items(project)
      assert issue_id == issue.id
    end

    test "POST .../items adds a readable issue from another repository", %{
      conn: conn,
      project: project
    } do
      source =
        repository_fixture(%{owner: "SourceOrg", name: "source-api", visibility: "public"})

      {:ok, issue} = Issues.create_issue(source, %{title: "Cross-repository work"})

      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{issue: %{owner: "SourceOrg", repo: "source-api", number: issue.number}}
        )

      assert %{
               "items" => [
                 %{
                   "issue_id" => issue_id,
                   "issue" => %{
                     "owner" => "SourceOrg",
                     "repo" => "source-api",
                     "number" => number,
                     "html_url" => html_url
                   }
                 }
               ]
             } = json_response(conn, 201)

      assert issue_id == issue.id
      assert number == issue.number
      assert html_url =~ "/SourceOrg/source-api/issues/#{issue.number}"
      assert [%{issue_repository_id: source_id}] = Projects.list_project_items(project)
      assert source_id == source.id
    end

    test "POST .../items hides an unreadable source repository", %{
      conn: conn,
      project: project
    } do
      source =
        repository_fixture(%{owner: "SecretOrg", name: "secret-api", visibility: "private"})

      {:ok, issue} = Issues.create_issue(source, %{title: "Private work"})

      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{issue: %{owner: "SecretOrg", repo: "secret-api", number: issue.number}}
        )

      assert json_response(conn, 404) == %{"message" => "Not Found"}
      assert Projects.list_project_items(project) == []
    end

    test "POST .../projectsV2/:project_number/items stores field values", %{
      conn: conn,
      project: project,
      issue: issue
    } do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{
            issue_number: issue.number,
            values: %{"Status" => "In Progress"}
          }
        )

      assert %{"items" => [%{"values" => %{"Status" => "In Progress"}}]} =
               json_response(conn, 201)
    end

    test "POST .../projectsV2/:project_number/items returns 422 for non-map values", %{
      conn: conn,
      project: project,
      issue: issue
    } do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{
            issue_number: issue.number,
            values: "not-a-map"
          }
        )

      assert %{"errors" => %{"values" => _}} = json_response(conn, 422)
      assert Projects.list_project_items(project) == []
    end

    test "POST .../projectsV2/:project_number/items returns 422 without an issue_number", %{
      conn: conn,
      project: project
    } do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{}
        )

      assert %{"errors" => %{"issue_number" => _}} = json_response(conn, 422)
      assert Projects.list_project_items(project) == []
    end

    test "POST .../projectsV2/:project_number/items returns 422 for a non-numeric issue_number",
         %{conn: conn, project: project} do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{
            issue_number: "not-a-number"
          }
        )

      assert %{"errors" => %{"issue_number" => _}} = json_response(conn, 422)
      assert Projects.list_project_items(project) == []
    end

    test "POST .../projectsV2/:project_number/items returns 404 for an unknown issue", %{
      conn: conn,
      project: project
    } do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{
            issue_number: 999_999
          }
        )

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end

    test "POST .../projectsV2/:project_number/items returns 404 for a missing project", %{
      conn: conn,
      issue: issue
    } do
      conn =
        post(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/999999/items", %{
          issue_number: issue.number
        })

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
        patch(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items/#{item.id}",
          %{
            values: %{"Status" => "Done"}
          }
        )

      assert %{"items" => [%{"values" => %{"Status" => "Done"}}]} = json_response(conn, 200)
      assert Projects.get_project_item!(project, item.id).values == %{"Status" => "Done"}
    end

    test "PATCH .../items/:item_id keeps values it was not asked to change", %{
      conn: conn,
      project: project,
      item: item
    } do
      conn =
        patch(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items/#{item.id}",
          %{
            values: %{"Priority" => "P1"}
          }
        )

      assert %{"items" => [%{"values" => values}]} = json_response(conn, 200)
      assert values == %{"Status" => "Todo", "Priority" => "P1"}
    end

    test "PATCH .../items/:item_id returns 422 for non-map values", %{
      conn: conn,
      project: project,
      item: item
    } do
      conn =
        patch(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items/#{item.id}",
          %{
            values: "not-a-map"
          }
        )

      assert %{"errors" => %{"values" => _}} = json_response(conn, 422)
      assert Projects.get_project_item!(project, item.id).values == %{"Status" => "Todo"}
    end

    test "PATCH .../items/:item_id returns 404 for a missing item", %{
      conn: conn,
      project: project
    } do
      conn =
        patch(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items/999999",
          %{
            values: %{"Status" => "Done"}
          }
        )

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end
  end

  describe "fields" do
    test "GET .../projectsV2/:project_number/fields returns an empty list for a new project", %{
      conn: conn
    } do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn =
        get(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields"
        )

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

      conn =
        get(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields"
        )

      assert %{"fields" => [rendered]} = json_response(conn, 200)
      assert rendered["id"] == field.id
      assert rendered["name"] == "Status"
      assert rendered["data_type"] == "single_select"
      assert rendered["options"] == %{"values" => ["Todo", "Done"]}
    end

    test "GET .../projectsV2/:project_number/fields returns 404 for a missing project", %{
      conn: conn
    } do
      conn = get(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/999999/fields")

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end

    test "POST .../projectsV2/:project_number/fields creates a field", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields",
          %{
            name: "Status",
            data_type: "single_select",
            options: %{values: ["To Do", "In Progress", "Done"]}
          }
        )

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

      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields",
          %{}
        )

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
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields",
          %{
            name: "Status",
            data_type: "single_select",
            project_id: other_project.id
          }
        )

      assert json_response(conn, 201)
      assert [%{project_id: project_id}] = Projects.list_project_fields(project)
      assert project_id == project.id
      assert Projects.list_project_fields(other_project) == []
    end
  end

  describe "repository authorization" do
    test "a non-member cannot read or mutate a private repository's project" do
      project = project_fixture(%{title: "Alice only", owner: "alice"})
      {:ok, issue} = create_issue(%{title: "Tracked"})
      mallory_conn = put_forge_api_token(build_conn(), "project-mallory", "mallory")

      {:ok, item} =
        Projects.create_project_item(%{"issue_number" => issue.number}, project)

      _field =
        project_field_fixture(%{
          project_id: project.id,
          name: "Status",
          data_type: "single_select"
        })

      assert get(
               mallory_conn,
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}"
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert get(
               recycle(mallory_conn),
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items"
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert get(
               recycle(mallory_conn),
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields"
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert post(
               recycle(mallory_conn),
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
               %{issue_number: issue.number}
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert patch(
               recycle(mallory_conn),
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items/#{item.id}",
               %{values: %{"Status" => "Done"}}
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert post(
               recycle(mallory_conn),
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields",
               %{name: "Priority", data_type: "single_select"}
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert Projects.get_project_item!(project, item.id).values == %{}
    end

    test "a token owner cannot create a project in another repository", %{conn: conn} do
      other_repository =
        repository_fixture(%{owner: "OtherOrg", name: "other-private", visibility: "private"})

      assert post(conn, ~p"/api/v3/repos/OtherOrg/other-private/projectsV2", %{
               title: "Not Alice's"
             })
             |> json_response(404) == %{"message" => "Not Found"}

      assert Projects.list_projects(other_repository) == []
    end
  end

  defp repository, do: Process.get({__MODULE__, :repository})

  defp project_fixture(attrs) do
    OpenAgents.ProjectsFixtures.project_fixture(repository(), attrs)
  end

  defp project_item_fixture(attrs) do
    OpenAgents.ProjectItemsFixtures.project_item_fixture(repository(), attrs)
  end

  defp project_field_fixture(attrs) do
    OpenAgents.ProjectFieldsFixtures.project_field_fixture(repository(), attrs)
  end

  defp create_issue(attrs), do: Issues.create_issue(repository(), attrs)
end
