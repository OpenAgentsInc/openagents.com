defmodule OpenAgentsWeb.ProjectControllerTest do
  use OpenAgentsWeb.ConnCase

  import OpenAgents.CompensationFixtures

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

  describe "promise registries" do
    test "LIVE projections require and expose an accepted outcome", %{conn: conn} do
      project = project_fixture(%{title: "Promises", owner: "alice"})

      {:ok, _field} =
        Projects.create_project_field(%{
          project_id: project.id,
          name: "Promise state",
          data_type: "promise_state",
          options: %{"values" => ["LIVE", "GATED", "WITHDRAWN"]}
        })

      {:ok, issue} = create_issue(%{title: "Accepted outcome promise"})
      decision = outcome_decision_fixture()

      values =
        promise_values("LIVE", "accepted")
        |> put_in(["promise", "evidence"], [
          %{
            "kind" => "accepted_outcome",
            "decision_receipt_ref" => decision.decision_receipt_ref
          }
        ])

      {:ok, _item} =
        Projects.create_project_item(
          %{"issue_number" => issue.number, "values" => values},
          project
        )

      conn =
        get(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items?promise_state=LIVE"
        )

      assert %{
               "items" => [
                 %{
                   "openagents" => %{
                     "promise" => %{
                       "record" => %{"id" => "accepted"},
                       "state" => "LIVE",
                       "bounty_candidate" => false
                     }
                   }
                 }
               ]
             } = json_response(conn, 200)
    end

    test "projects expose promise projections and promise filters", %{conn: conn} do
      project = project_fixture(%{title: "Promises", owner: "alice"})

      {:ok, _field} =
        Projects.create_project_field(%{
          project_id: project.id,
          name: "Promise state",
          data_type: "promise_state",
          options: %{"values" => ["LIVE", "GATED", "WITHDRAWN"]}
        })

      {:ok, gated_issue} = create_issue(%{title: "Gated promise"})
      {:ok, withdrawn_issue} = create_issue(%{title: "Withdrawn promise"})

      {:ok, _gated_item} =
        Projects.create_project_item(
          %{"issue_number" => gated_issue.number, "values" => promise_values("GATED", "gated")},
          project
        )

      withdrawn_values =
        promise_values("WITHDRAWN", "withdrawn")
        |> put_in(["promise", "withdrawal"], %{
          "reason" => "Replaced",
          "replacement" => "A new promise",
          "date" => "2026-08-23"
        })

      {:ok, _withdrawn_item} =
        Projects.create_project_item(
          %{
            "issue_number" => withdrawn_issue.number,
            "values" => withdrawn_values
          },
          project
        )

      conn =
        get(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items?promise_state=GATED&bounty_candidate=true"
        )

      assert %{
               "items" => [
                 %{
                   "openagents" => %{
                     "promise" => %{
                       "record" => %{"id" => "gated"},
                       "state" => "GATED",
                       "bounty_candidate" => true
                     }
                   }
                 }
               ]
             } = json_response(conn, 200)
    end

    test "promise item events are paginated and actor-attributed", %{conn: conn, user: user} do
      project = project_fixture(%{title: "Promises", owner: "alice"})

      {:ok, _field} =
        Projects.create_project_field(%{
          project_id: project.id,
          name: "Promise state",
          data_type: "promise_state",
          options: %{"values" => ["LIVE", "GATED", "WITHDRAWN"]}
        })

      {:ok, issue} = create_issue(%{title: "Gated promise"})

      {:ok, item} =
        Projects.create_project_item(
          %{"issue_number" => issue.number, "values" => promise_values("GATED", "events")},
          project,
          user
        )

      conn =
        get(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items/#{item.id}/events"
        )

      assert %{
               "events" => [
                 %{"actor_login" => "alice", "kind" => "create", "to_state" => "GATED"}
               ],
               "pagination" => %{"page" => 1, "total" => 1}
             } = json_response(conn, 200)
    end

    test "anonymous readers can read a public registry" do
      project = project_fixture(%{title: "Public promises", owner: "alice"})

      {:ok, _field} =
        Projects.create_project_field(%{
          project_id: project.id,
          name: "Promise state",
          data_type: "promise_state",
          options: %{"values" => ["LIVE", "GATED", "WITHDRAWN"]}
        })

      {:ok, issue} = create_issue(%{title: "Public promise"})

      {:ok, _item} =
        Projects.create_project_item(
          %{"issue_number" => issue.number, "values" => promise_values("GATED", "public")},
          project
        )

      OpenAgents.Repo.update_all(
        OpenAgents.Repositories.Repository,
        set: [visibility: "public"]
      )

      conn =
        build_conn()
        |> get(~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items")

      assert %{"items" => [_item]} = json_response(conn, 200)
    end

    test "promise evidence from an unreadable repository is redacted", %{conn: conn} do
      project = project_fixture(%{title: "Promises", owner: "alice"})

      {:ok, _field} =
        Projects.create_project_field(%{
          project_id: project.id,
          name: "Promise state",
          data_type: "promise_state",
          options: %{"values" => ["LIVE", "GATED", "WITHDRAWN"]}
        })

      source =
        repository_fixture(%{owner: "SecretOrg", name: "secret-evidence", visibility: "private"})

      {:ok, secret_issue} = Issues.create_issue(source, %{title: "Secret evidence"})
      {:ok, visible_issue} = create_issue(%{title: "Visible promise"})

      values =
        promise_values("GATED", "redacted")
        |> put_in(["promise", "evidence"], [
          %{
            "kind" => "issue",
            "owner" => source.owner,
            "repo" => source.name,
            "number" => secret_issue.number
          }
        ])

      {:ok, _item} =
        Projects.create_project_item(
          %{"issue_number" => visible_issue.number, "values" => values},
          project
        )

      conn =
        get(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items")

      assert %{"items" => [%{"openagents" => %{"promise" => %{"record" => record}}}]} =
               json_response(conn, 200)

      assert record["evidence"] == []
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
            data_type: "text",
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
          data_type: "text"
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
               %{name: "Priority", data_type: "text"}
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

  describe "lifecycle" do
    test "PATCH projectsV2/:number closes, reopens, and archives a project", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice", state: "open"})
      path = ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}"

      assert %{"state" => "closed", "archived" => false} =
               conn |> patch(path, %{state: "closed"}) |> json_response(200)

      assert %{"state" => "open", "archived" => false} =
               conn |> patch(path, %{state: "open"}) |> json_response(200)

      assert %{"state" => "open", "archived" => true, "archived_at" => archived_at} =
               conn |> patch(path, %{archived: true}) |> json_response(200)

      assert is_binary(archived_at)
      assert Projects.get_project_by_number!(repository(), project.number).archived_at

      assert %{"archived" => false, "archived_at" => nil} =
               conn |> patch(path, %{archived: false}) |> json_response(200)

      refute Projects.get_project_by_number!(repository(), project.number).archived_at
    end

    test "PATCH projectsV2/:number rejects a non-boolean archived flag", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn =
        patch(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}", %{
          archived: "sideways"
        })

      assert json_response(conn, 422) == %{"errors" => %{"archived" => ["is invalid"]}}
      refute Projects.get_project_by_number!(repository(), project.number).archived_at
    end

    test "lifecycle transitions appear in the project's activity, attributed to the actor", %{
      conn: conn
    } do
      project = project_fixture(%{title: "Roadmap", owner: "alice", state: "open"})
      path = ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}"

      assert json_response(patch(conn, path, %{state: "closed"}), 200)
      assert json_response(patch(conn, path, %{archived: true}), 200)

      assert %{"notes" => notes} =
               conn
               |> get(
                 ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/notes?kind=activity"
               )
               |> json_response(200)

      bodies = Enum.map(notes, & &1["body"])
      assert Enum.any?(bodies, &(&1 =~ "Archived the project."))
      assert Enum.any?(bodies, &(&1 =~ "Changed the state to `closed`."))
      assert Enum.all?(notes, &(get_in(&1, ["author", "login"]) == "alice"))
    end

    test "DELETE projectsV2/:number refuses a project that is not archived", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn =
        delete(conn, ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}")

      assert %{"errors" => %{"archived" => [message]}} = json_response(conn, 422)
      assert message =~ "archived"
      assert Projects.get_project_by_number!(repository(), project.number)
    end

    test "DELETE projectsV2/:number removes an archived project, its fields, and its items", %{
      conn: conn
    } do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})
      {:ok, issue} = create_issue(%{title: "Tracked"})
      item = project_item_fixture(%{project_id: project.id, issue_id: issue.id})
      field = project_field_fixture(%{project_id: project.id, name: "Status", data_type: "text"})

      path = ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}"
      assert json_response(patch(conn, path, %{archived: true}), 200)
      assert response(delete(conn, path), 204) == ""

      assert_raise Ecto.NoResultsError, fn ->
        Projects.get_project_by_number!(repository(), project.number)
      end

      refute OpenAgents.Repo.get(OpenAgents.ProjectItems.ProjectItem, item.id)
      refute OpenAgents.Repo.get(OpenAgents.ProjectFields.ProjectField, field.id)
      # A project item is a reference to a canonical issue. Deleting the board
      # must never delete the work it pointed at.
      assert OpenAgents.Repo.get(OpenAgents.Issues.Issue, issue.id)
    end

    test "DELETE projectsV2/:number hides a private repository from a non-member", %{conn: conn} do
      project = project_fixture(%{title: "Alice only", owner: "alice"})
      path = ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}"
      assert json_response(patch(conn, path, %{archived: true}), 200)

      mallory = put_forge_api_token(build_conn(), "project-mallory-delete", "mallory")

      assert delete(mallory, path) |> json_response(404) == %{"message" => "Not Found"}
      assert Projects.get_project_by_number!(repository(), project.number)
    end

    test "an archived project stays out of the default list and returns on request", %{
      conn: conn
    } do
      kept = project_fixture(%{title: "Kept", owner: "alice"})
      retired = project_fixture(%{title: "Retired", owner: "alice"})

      assert json_response(
               patch(
                 conn,
                 ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{retired.number}",
                 %{archived: true}
               ),
               200
             )

      assert %{"projects" => listed} =
               conn
               |> get(~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2")
               |> json_response(200)

      assert Enum.map(listed, & &1["number"]) == [kept.number]

      assert %{"projects" => all} =
               conn
               |> get(~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2?archived=true")
               |> json_response(200)

      assert Enum.sort(Enum.map(all, & &1["number"])) == Enum.sort([kept.number, retired.number])
    end
  end

  describe "field validation" do
    test "POST fields rejects an unsupported data type", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields",
          %{name: "Status", data_type: "rocket"}
        )

      assert %{"errors" => %{"data_type" => [_ | _]}} = json_response(conn, 422)
      assert Projects.list_project_fields(project) == []
    end

    test "POST fields rejects a duplicate name, ignoring case", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})
      path = ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields"

      assert json_response(post(conn, path, %{name: "Status", data_type: "text"}), 201)

      conn = post(conn, path, %{name: "status", data_type: "text"})

      assert %{"errors" => %{"name" => [_ | _]}} = json_response(conn, 422)
      assert length(Projects.list_project_fields(project)) == 1
    end

    test "POST fields allows the same name on a different project", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})
      other = project_fixture(%{title: "Other", owner: "alice"})

      for board <- [project, other] do
        assert json_response(
                 post(
                   conn,
                   ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{board.number}/fields",
                   %{name: "Status", data_type: "text"}
                 ),
                 201
               )
      end
    end

    test "POST fields requires options for a single select", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields",
          %{name: "Status", data_type: "single_select"}
        )

      assert %{"errors" => %{"options" => [_ | _]}} = json_response(conn, 422)
      assert Projects.list_project_fields(project) == []
    end

    test "POST fields rejects duplicate option identifiers", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields",
          %{name: "Status", data_type: "single_select", options: %{values: ["Todo", "Todo"]}}
        )

      assert %{"errors" => %{"options" => [_ | _]}} = json_response(conn, 422)
      assert Projects.list_project_fields(project) == []
    end

    test "POST fields keeps explicit option identifiers alongside their names", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields",
          %{
            name: "Status",
            data_type: "single_select",
            options: %{
              values: [%{id: "todo", name: "To do"}, %{id: "done", name: "Done"}]
            }
          }
        )

      assert %{"fields" => [%{"options" => options}]} = json_response(conn, 201)

      assert options == %{
               "values" => [
                 %{"id" => "todo", "name" => "To do"},
                 %{"id" => "done", "name" => "Done"}
               ]
             }
    end

    test "POST fields rejects options on a data type that carries none", %{conn: conn} do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields",
          %{name: "Points", data_type: "number", options: %{values: ["1", "2"]}}
        )

      assert %{"errors" => %{"options" => [_ | _]}} = json_response(conn, 422)
      assert Projects.list_project_fields(project) == []
    end
  end

  describe "update_field" do
    setup do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      field =
        project_field_fixture(%{
          project_id: project.id,
          name: "Status",
          data_type: "single_select",
          options: %{"values" => ["Todo", "Done"]}
        })

      %{project: project, field: field}
    end

    test "PATCH fields/:field_id renames a field and rewrites stored item values", %{
      conn: conn,
      project: project,
      field: field
    } do
      item = project_item_fixture(%{project_id: project.id, values: %{"Status" => "Todo"}})

      conn =
        patch(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields/#{field.id}",
          %{name: "Stage"}
        )

      assert %{"fields" => [%{"name" => "Stage", "id" => id}]} = json_response(conn, 200)
      assert id == field.id
      assert Projects.get_project_item!(project, item.id).values == %{"Stage" => "Todo"}
    end

    test "PATCH fields/:field_id refuses to change the data type", %{
      conn: conn,
      project: project,
      field: field
    } do
      conn =
        patch(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields/#{field.id}",
          %{data_type: "text"}
        )

      assert %{"errors" => %{"data_type" => [_ | _]}} = json_response(conn, 422)
      assert Projects.get_project_field!(project, field.id).data_type == "single_select"
    end

    test "PATCH fields/:field_id adds an option", %{
      conn: conn,
      project: project,
      field: field
    } do
      conn =
        patch(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields/#{field.id}",
          %{options: %{values: ["Todo", "In progress", "Done"]}}
        )

      assert %{"fields" => [%{"options" => %{"values" => values}}]} = json_response(conn, 200)
      assert values == ["Todo", "In progress", "Done"]
    end

    test "PATCH fields/:field_id refuses to remove an option items still carry", %{
      conn: conn,
      project: project,
      field: field
    } do
      item = project_item_fixture(%{project_id: project.id, values: %{"Status" => "Todo"}})

      conn =
        patch(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields/#{field.id}",
          %{options: %{values: ["Done"]}}
        )

      assert %{"errors" => %{"options" => [message]}} = json_response(conn, 422)
      assert message =~ "Todo"

      assert Projects.get_project_field!(project, field.id).options == %{
               "values" => ["Todo", "Done"]
             }

      assert Projects.get_project_item!(project, item.id).values == %{"Status" => "Todo"}
    end

    test "PATCH fields/:field_id refuses a name another field already carries", %{
      conn: conn,
      project: project,
      field: field
    } do
      project_field_fixture(%{project_id: project.id, name: "Priority", data_type: "text"})

      conn =
        patch(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields/#{field.id}",
          %{name: "Priority"}
        )

      assert %{"errors" => %{"name" => [_ | _]}} = json_response(conn, 422)
      assert Projects.get_project_field!(project, field.id).name == "Status"
    end

    test "PATCH fields/:field_id returns 404 for a field on another project", %{
      conn: conn,
      field: field
    } do
      other = project_fixture(%{title: "Other", owner: "alice"})

      conn =
        patch(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{other.number}/fields/#{field.id}",
          %{name: "Stage"}
        )

      assert json_response(conn, 404) == %{"message" => "Not Found"}
    end

    test "PATCH fields/:field_id hides a private repository from a non-member", %{
      project: project,
      field: field
    } do
      mallory = put_forge_api_token(build_conn(), "project-mallory-field", "mallory")

      assert patch(
               mallory,
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields/#{field.id}",
               %{name: "Mine now"}
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert Projects.get_project_field!(project, field.id).name == "Status"
    end
  end

  describe "delete_field" do
    setup do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})

      field =
        project_field_fixture(%{
          project_id: project.id,
          name: "Status",
          data_type: "single_select",
          options: %{"values" => ["Todo", "Done"]}
        })

      %{project: project, field: field}
    end

    test "DELETE fields/:field_id removes a field no item carries", %{
      conn: conn,
      project: project,
      field: field
    } do
      conn =
        delete(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields/#{field.id}"
        )

      assert response(conn, 204) == ""
      assert Projects.list_project_fields(project) == []
    end

    test "DELETE fields/:field_id refuses a field items still carry", %{
      conn: conn,
      project: project,
      field: field
    } do
      item = project_item_fixture(%{project_id: project.id, values: %{"Status" => "Todo"}})

      conn =
        delete(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields/#{field.id}"
        )

      assert %{"errors" => %{"name" => [message]}} = json_response(conn, 422)
      assert message =~ "1"
      assert Projects.get_project_field!(project, field.id)
      assert Projects.get_project_item!(project, item.id).values == %{"Status" => "Todo"}
    end

    test "DELETE fields/:field_id hides a private repository from a non-member", %{
      project: project,
      field: field
    } do
      mallory = put_forge_api_token(build_conn(), "project-mallory-field-delete", "mallory")

      assert delete(
               mallory,
               ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/fields/#{field.id}"
             )
             |> json_response(404) == %{"message" => "Not Found"}

      assert Projects.get_project_field!(project, field.id)
    end
  end

  describe "item values against stored fields" do
    setup do
      project = project_fixture(%{title: "Roadmap", owner: "alice"})
      {:ok, issue} = create_issue(%{title: "Tracked"})

      project_field_fixture(%{
        project_id: project.id,
        name: "Status",
        data_type: "single_select",
        options: %{"values" => ["Todo", "Done"]}
      })

      project_field_fixture(%{project_id: project.id, name: "Points", data_type: "number"})
      project_field_fixture(%{project_id: project.id, name: "Due", data_type: "date"})

      %{project: project, issue: issue}
    end

    test "POST items accepts a value a field declares", %{
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
            values: %{"Status" => "Done", "Points" => 3, "Due" => "2026-09-01"}
          }
        )

      assert %{"items" => [%{"values" => values}]} = json_response(conn, 201)
      assert values == %{"Status" => "Done", "Points" => 3, "Due" => "2026-09-01"}
    end

    test "POST items rejects a value outside a single select's options", %{
      conn: conn,
      project: project,
      issue: issue
    } do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{issue_number: issue.number, values: %{"Status" => "Sideways"}}
        )

      assert %{"errors" => %{"values" => [message]}} = json_response(conn, 422)
      assert message =~ "Status"
      assert Projects.list_project_items(project) == []
    end

    test "POST items rejects a non-numeric number and a non-ISO date", %{
      conn: conn,
      project: project,
      issue: issue
    } do
      path = ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items"

      assert %{"errors" => %{"values" => [_ | _]}} =
               conn
               |> post(path, %{issue_number: issue.number, values: %{"Points" => "many"}})
               |> json_response(422)

      assert %{"errors" => %{"values" => [_ | _]}} =
               conn
               |> post(path, %{issue_number: issue.number, values: %{"Due" => "next Tuesday"}})
               |> json_response(422)

      assert Projects.list_project_items(project) == []
    end

    test "POST items keeps a value for a field the project has not declared", %{
      conn: conn,
      project: project,
      issue: issue
    } do
      conn =
        post(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items",
          %{issue_number: issue.number, values: %{"Squad" => "Platform"}}
        )

      assert %{"items" => [%{"values" => %{"Squad" => "Platform"}}]} = json_response(conn, 201)
    end

    test "PATCH items/:item_id rejects a value outside a single select's options", %{
      conn: conn,
      project: project,
      issue: issue
    } do
      item =
        project_item_fixture(%{
          project_id: project.id,
          issue_id: issue.id,
          values: %{"Status" => "Todo"}
        })

      conn =
        patch(
          conn,
          ~p"/api/v3/repos/ProjectTestOrg/project-api/projectsV2/#{project.number}/items/#{item.id}",
          %{values: %{"Status" => "Sideways"}}
        )

      assert %{"errors" => %{"values" => [_ | _]}} = json_response(conn, 422)
      assert Projects.get_project_item!(project, item.id).values == %{"Status" => "Todo"}
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

  defp promise_values(state, id) do
    record = %{
      "id" => id,
      "problem" => "A problem",
      "claim" => "A claim",
      "scope" => "A scope",
      "acceptance_criteria" => ["A criterion"],
      "success_metrics" => ["A metric"],
      "owner" => "OpenAgents",
      "target" => "2026-12-31",
      "evidence" => [],
      "gate" => %{
        "missing" => "A receipt",
        "owner" => "OpenAgents",
        "next_review" => "2026-09-01"
      }
    }

    %{"Promise state" => state, "promise" => record}
  end
end
