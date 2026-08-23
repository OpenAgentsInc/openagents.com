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

    test "POST /api/v3/repos/:owner/:repo/projectsV2 accepts a Markdown description", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2", %{
          title: "Stress testing Ox Alpha",
          description: "## Why\n\nProvider order is under test."
        })

      assert %{"description" => "## Why\n\nProvider order is under test."} =
               json_response(conn, 201)
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

    test "GET .../projectsV2/:project_number/items omits an unreadable source issue", %{
      conn: conn
    } do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})
      {:ok, local_issue} = create_issue(%{title: "Local work"})

      {:ok, _local_item} =
        Projects.create_project_item(%{"issue_number" => local_issue.number}, project)

      source =
        repository_fixture(%{owner: "HiddenOrg", name: "hidden-api", visibility: "private"})

      {:ok, hidden_issue} = Issues.create_issue(source, %{title: "Confidential work"})

      {:ok, _hidden_item} =
        Projects.create_project_item(
          %{"issue_number" => hidden_issue.number, "issue_repository_id" => source.id},
          project
        )

      conn =
        get(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items")

      body = response(conn, 200)
      refute body =~ "hidden-api"
      refute body =~ "HiddenOrg"

      assert %{"items" => [%{"issue" => %{"repo" => "project-api", "number" => number}}]} =
               Jason.decode!(body)

      assert number == local_issue.number
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

    test "POST .../items adds a private source issue the member can read", %{
      conn: conn,
      project: project,
      user: user
    } do
      source =
        repository_with_member_fixture(
          user,
          %{owner: "ReadableOrg", name: "readable-api", visibility: "private"},
          "viewer"
        )

      {:ok, issue} = Issues.create_issue(source, %{title: "Private but readable"})

      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{issue: %{owner: "ReadableOrg", repo: "readable-api", number: issue.number}}
        )

      assert %{"items" => [%{"issue_id" => issue_id}]} = json_response(conn, 201)
      assert issue_id == issue.id
    end

    test "POST .../items refuses a project reader who can write the source repository", %{
      project: project,
      repository: repository
    } do
      reader = github_user("api-token-project-reader", "carol")
      {:ok, _membership} = OpenAgents.Repositories.add_member(repository, reader, "viewer")

      source =
        repository_with_member_fixture(
          reader,
          %{owner: "WriterOrg", name: "writer-api", visibility: "private"},
          "owner"
        )

      {:ok, issue} = Issues.create_issue(source, %{title: "Their own work"})

      conn =
        post(
          put_forge_api_token(build_conn(), "project-reader", "carol"),
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{issue: %{owner: "WriterOrg", repo: "writer-api", number: issue.number}}
        )

      assert json_response(conn, 404) == %{"message" => "Not Found"}
      assert Projects.list_project_items(project) == []
    end

    test "POST .../items returns 404 for an unknown source repository", %{
      conn: conn,
      project: project
    } do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{issue: %{owner: "NoSuchOrg", repo: "no-such-api", number: 1}}
        )

      assert json_response(conn, 404) == %{"message" => "Not Found"}
      assert Projects.list_project_items(project) == []
    end

    test "POST .../items returns 404 for an unknown issue in a readable source repository", %{
      conn: conn,
      project: project
    } do
      repository_fixture(%{owner: "SourceOrg", name: "empty-api", visibility: "public"})

      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{issue: %{owner: "SourceOrg", repo: "empty-api", number: 999_999}}
        )

      assert json_response(conn, 404) == %{"message" => "Not Found"}
      assert Projects.list_project_items(project) == []
    end

    test "POST .../items reads the number in the named source repository", %{
      conn: conn,
      project: project,
      issue: issue
    } do
      source =
        repository_fixture(%{owner: "SourceOrg", name: "same-number-api", visibility: "public"})

      {:ok, source_issue} = Issues.create_issue(source, %{title: "Same number elsewhere"})
      assert source_issue.number == issue.number

      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{issue: %{owner: "SourceOrg", repo: "same-number-api", number: source_issue.number}}
        )

      assert %{"items" => [%{"issue_id" => issue_id}]} = json_response(conn, 201)
      assert issue_id == source_issue.id
      refute issue_id == issue.id
    end

    test "POST .../items refuses the same source issue twice", %{
      conn: conn,
      project: project
    } do
      source =
        repository_fixture(%{owner: "SourceOrg", name: "repeat-api", visibility: "public"})

      {:ok, issue} = Issues.create_issue(source, %{title: "Added once"})
      body = %{issue: %{owner: "SourceOrg", repo: "repeat-api", number: issue.number}}
      path = ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items"

      assert %{"items" => [_item]} = json_response(post(conn, path, body), 201)
      assert %{"errors" => _errors} = json_response(post(conn, path, body), 422)
      assert length(Projects.list_project_items(project)) == 1
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

    test "PATCH .../items/:item_id returns 404 for an unreadable source issue", %{
      conn: conn,
      project: project
    } do
      source =
        repository_fixture(%{owner: "HiddenOrg", name: "hidden-patch-api", visibility: "private"})

      {:ok, issue} = Issues.create_issue(source, %{title: "Confidential work"})

      {:ok, item} =
        Projects.create_project_item(
          %{"issue_number" => issue.number, "issue_repository_id" => source.id},
          project
        )

      conn =
        patch(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items/#{item.id}",
          %{values: %{"Status" => "Done"}}
        )

      assert json_response(conn, 404) == %{"message" => "Not Found"}
      assert Projects.get_project_item!(project, item.id).values == %{}
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

  describe "update" do
    test "PATCH projectsV2/:number updates the title, description, and state", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice", state: "open"})

      conn =
        patch(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}", %{
          title: "Stress testing Ox Alpha",
          description: "## Why\n\nProvider order is under test.",
          state: "closed"
        })

      assert %{
               "title" => "Stress testing Ox Alpha",
               "description" => "## Why\n\nProvider order is under test.",
               "state" => "closed",
               "created_at" => _created,
               "updated_at" => _updated
             } = json_response(conn, 200)
    end

    test "PATCH projectsV2/:number ignores fields it does not own", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn =
        patch(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}", %{
          title: "Renamed",
          number: 9999,
          owner: "mallory"
        })

      assert %{"title" => "Renamed", "number" => number, "owner" => "alice"} =
               json_response(conn, 200)

      assert number == project.number
    end

    test "PATCH projectsV2/:number rejects an unknown state", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice", state: "open"})

      conn =
        patch(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}", %{
          state: "sideways"
        })

      assert json_response(conn, 422) == %{"errors" => %{"state" => ["is invalid"]}}
      assert Projects.get_project_by_number!(repository(), project.number).state == "open"
    end

    test "PATCH projectsV2/:number hides a private repository from a non-member", %{conn: _conn} do
      project = project_fixture(%{title: "Alice only", owner: "alice"})
      mallory = put_forge_api_token(build_conn(), "project-mallory-update", "mallory")

      assert patch(
               mallory,
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}",
               %{title: "Mine now"}
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert Projects.get_project_by_number!(repository(), project.number).title == "Alice only"
    end
  end

  describe "notes" do
    test "GET and POST notes round-trip a Markdown note with its author", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      created =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes",
          %{body: "- paused lane 3"}
        )

      assert %{
               "id" => id,
               "kind" => "note",
               "body" => "- paused lane 3",
               "author" => %{"login" => "alice"},
               "created_at" => _created_at,
               "updated_at" => _updated_at
             } = json_response(created, 201)

      listed =
        get(
          recycle(conn),
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes"
        )

      assert %{"notes" => [note], "page" => 1, "per_page" => per_page, "total_count" => 1} =
               json_response(listed, 200)

      assert note["id"] == id
      assert per_page == Projects.notes_per_page()
    end

    test "GET notes paginates and filters by kind", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice", state: "open"})
      user = github_user("api-token-projects", "alice")

      for index <- 1..(Projects.notes_per_page() + 1) do
        {:ok, _note} =
          Projects.create_project_note(project, %{"body" => "note #{index}"}, user)
      end

      {:ok, _updated} = Projects.update_project(project, %{"state" => "closed"}, user)

      page_two =
        get(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes?page=2"
        )

      assert %{"notes" => notes, "page" => 2} = json_response(page_two, 200)
      assert length(notes) == 2

      activity =
        get(
          recycle(conn),
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes?kind=activity"
        )

      assert %{"notes" => [%{"kind" => "activity", "body" => body}], "total_count" => 1} =
               json_response(activity, 200)

      assert body =~ "closed"
    end

    test "only the author may edit or delete a note", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})
      author = github_user("api-token-projects", "alice")
      {:ok, note} = Projects.create_project_note(project, %{"body" => "mine"}, author)

      mallory_conn =
        put_forge_api_token(build_conn(), "project-mallory-notes", "mallory", repository())

      assert patch(
               mallory_conn,
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes/#{note.id}",
               %{body: "not mine"}
             )
             |> json_response(403) == %{"message" => "Forbidden"}

      assert delete(
               recycle(mallory_conn),
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes/#{note.id}"
             )
             |> json_response(403) == %{"message" => "Forbidden"}

      assert patch(
               conn,
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes/#{note.id}",
               %{body: "mine, edited"}
             )
             |> json_response(200)
             |> Map.fetch!("body") == "mine, edited"

      assert delete(
               recycle(conn),
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes/#{note.id}"
             )
             |> response(204)

      assert Projects.count_project_notes(project) == 0
    end

    test "an activity entry cannot be edited or deleted", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice", state: "open"})
      user = github_user("api-token-projects", "alice")
      {:ok, _updated} = Projects.update_project(project, %{"state" => "closed"}, user)

      {[activity], 1} = Projects.list_project_notes_page(project, kind: "activity")

      assert patch(
               conn,
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes/#{activity.id}",
               %{body: "rewritten"}
             )
             |> json_response(403) == %{"message" => "Forbidden"}

      assert delete(
               recycle(conn),
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes/#{activity.id}"
             )
             |> json_response(403) == %{"message" => "Forbidden"}

      assert Projects.count_project_notes(project, kind: "activity") == 1
    end

    test "notes on a private repository stay hidden from a non-member", %{conn: conn} do
      project = project_fixture(%{title: "Alice only", owner: "alice"})

      {:ok, _note} =
        Projects.create_project_note(
          project,
          %{"body" => "private context"},
          github_user("api-token-projects", "alice")
        )

      assert get(
               build_conn(),
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes"
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert post(
               put_forge_api_token(build_conn(), "project-outsider-notes", "outsider"),
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes",
               %{body: "mine now"}
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert %{"notes" => [_note]} =
               get(
                 conn,
                 ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes"
               )
               |> json_response(200)
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
