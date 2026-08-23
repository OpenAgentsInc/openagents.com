defmodule OpenAgentsWeb.IssueControllerTest do
  use OpenAgentsWeb.ConnCase

  setup %{conn: conn}, do: {:ok, conn: put_forge_api_token(conn, "issues", repository())}

  alias OpenAgents.Issues
  alias OpenAgents.Agents
  alias OpenAgents.Accounts
  alias OpenAgents.Repo
  alias OpenAgents.Repositories

  import OpenAgents.MilestonesFixtures
  import OpenAgents.LabelsFixtures

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

    test "an unlinked agent can create an issue with an agent author", %{conn: conn} do
      {:ok, agent, credential} =
        Agents.register(%{
          handle: "issue-agent",
          display_name: "Issue agent",
          registration_ip: "192.0.2.50"
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{credential}")
        |> post(~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues", %{
          title: "Agent issue",
          body: "Filed without a human link"
        })

      assert %{"user" => %{"agent" => true, "handle" => "issue-agent"}} =
               json_response(conn, 201)

      assert Repo.get_by(OpenAgents.Issues.Issue, title: "Agent issue").author_agent_id ==
               agent.id
    end

    test "a suspended agent is refused on issue creation", %{conn: conn} do
      {:ok, agent, credential} =
        Agents.register(%{
          handle: "suspended-issue-bot",
          display_name: "Suspended issue bot",
          registration_ip: "192.0.2.52"
        })

      assert {:ok, _suspended} = Agents.suspend(agent, "test")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{credential}")
        |> post(~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues", %{
          title: "Should fail",
          body: "Suspended"
        })

      assert conn.status == 401
    end

    test "an agent credential is refused on private repository issue creation", %{conn: conn} do
      private =
        repository_fixture(%{
          owner: "PrivateOwner",
          name: "private-repository",
          visibility: "private"
        })

      {:ok, _agent, credential} =
        Agents.register(%{
          handle: "private-issue-bot",
          display_name: "Private issue bot",
          registration_ip: "192.0.2.53"
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{credential}")
        |> post("/api/v3/repos/#{private.owner}/#{private.name}/issues", %{
          title: "Should fail",
          body: "Private"
        })

      assert conn.status == 404
    end

    test "linking and unlinking do not rewrite issue authorship", %{conn: conn} do
      {:ok, agent, credential} =
        Agents.register(%{
          handle: "stable-issue-bot",
          display_name: "Stable issue bot",
          registration_ip: "192.0.2.54"
        })

      {:ok, user} =
        Accounts.upsert_github_user(%{
          github_id: 992_054,
          github_login: "stable-issue-reviewer",
          github_avatar_url: "https://avatars.githubusercontent.com/u/992054?v=4"
        })

      created =
        conn
        |> put_req_header("authorization", "Bearer #{credential}")
        |> post(~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues", %{
          title: "Stable issue",
          body: "Authorship must remain stable"
        })

      assert %{"number" => number, "user" => before_author} = json_response(created, 201)
      assert {:ok, pending} = Agents.request_link(agent, user)
      assert {:ok, _linked} = Agents.accept_link(user, pending.id)
      assert {:ok, _unlinked} = Agents.unlink(agent, user)

      after_link =
        get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{number}")
        |> json_response(200)

      assert after_link["user"] == before_author
      assert before_author["agent"] == true
      refute Map.has_key?(before_author, "owner")
    end

    test "a linked agent cannot close an issue through the human-only update route", %{conn: conn} do
      owner = repository_user_fixture("issue-close-agent-owner")
      repository = repository_with_member_fixture(owner)
      {:ok, issue} = Issues.create_issue(repository, %{title: "Must remain open"})

      {:ok, agent, credential} =
        Agents.register(%{
          handle: "issue-close-agent",
          display_name: "Issue close agent",
          registration_ip: "192.0.2.54"
        })

      {:ok, link} = Agents.request_link(agent, owner)
      {:ok, _linked} = Agents.accept_link(owner, link.id)
      assert {:ok, _grant} = Agents.grant_box_control(owner, agent)

      response =
        conn
        |> put_req_header("authorization", "Bearer #{credential}")
        |> patch(
          "/api/v3/repos/#{repository.owner}/#{repository.name}/issues/#{issue.number}",
          %{state: "closed"}
        )

      assert json_response(response, 401) == %{"error" => "invalid_api_token"}
      assert Repo.get!(OpenAgents.Issues.Issue, issue.id).state == "open"
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

  describe "pagination and filters" do
    test "index returns bounded pagination metadata", %{conn: conn} do
      {:ok, _issue} = Issues.create_issue(repository(), %{title: "Counted issue"})

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues")

      assert %{"issues" => issues, "pagination" => pagination} = json_response(conn, 200)
      assert length(issues) <= Issues.per_page()
      assert pagination["page"] == 1
      assert pagination["per_page"] == Issues.per_page()
      assert pagination["total"] == 1
      assert pagination["total_pages"] == 1
    end

    test "index filters by label, assignee, milestone, and search", %{conn: conn} do
      milestone_fixture(repository(), %{number: 3, title: "Sprint 3"})
      label_fixture(repository(), %{name: "bug", color: "d73a4a"})

      octavia = github_user("assignee-filter", "octavia")
      {:ok, _membership} = Repositories.add_member(repository(), octavia, "owner")

      {:ok, _matched} =
        Issues.create_issue(repository(), %{
          title: "Wombat routing",
          labels: [%{"name" => "bug"}],
          assignees: [%{"login" => "octavia"}],
          milestone: %{"number" => 3}
        })

      {:ok, _other} = Issues.create_issue(repository(), %{title: "Unrelated"})

      for params <- [
            %{"labels" => "bug"},
            %{"assignee" => "octavia"},
            %{"milestone" => "3"},
            %{"q" => "wombat"}
          ] do
        conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?#{params}")
        assert %{"issues" => [issue], "pagination" => %{"total" => 1}} = json_response(conn, 200)
        assert issue["title"] == "Wombat routing"
      end
    end

    test "index pages through results in a stable order", %{conn: conn} do
      Enum.each(1..30, fn n ->
        {:ok, _} = Issues.create_issue(repository(), %{title: "Paged #{n}"})
      end)

      first = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues")

      assert %{"issues" => page_one, "pagination" => %{"total_pages" => 2}} =
               json_response(first, 200)

      assert length(page_one) == Issues.per_page()

      second =
        get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?page=2")

      assert %{"issues" => page_two} = json_response(second, 200)
      assert length(page_two) == 30 - Issues.per_page()
      page_one_titles = MapSet.new(page_one, & &1["title"])
      refute Enum.any?(page_two, &MapSet.member?(page_one_titles, &1["title"]))
    end

    test "index rejects an unknown state with a stable error", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?state=bogus")

      assert %{"errors" => %{"state" => [message]}} = json_response(conn, 422)
      assert message =~ "open"
    end

    test "index rejects a non-integer page with a stable error", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?page=zero")

      assert %{"errors" => %{"page" => [message]}} = json_response(conn, 422)
      assert message =~ "positive integer"
    end
  end

  describe "the openagents issue extension" do
    test "show carries the dependency graph and names the extension", %{conn: conn} do
      {:ok, blocked} = Issues.create_issue(repository(), %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository(), %{title: "Prerequisite"})
      assert :ok = Issues.add_dependencies(blocked, [blocker.number])

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{blocked.number}")

      assert %{
               "openagents" => %{
                 "blocked" => true,
                 "blocked_by" => [%{"number" => number, "state" => "open"}],
                 "blocks" => []
               }
             } = json_response(conn, 200)

      assert number == blocker.number
      assert get_resp_header(conn, "x-openagents-extensions") == ["issue.openagents"]
    end

    test "index carries the graph for every issue on the page", %{conn: conn} do
      {:ok, blocked} = Issues.create_issue(repository(), %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository(), %{title: "Prerequisite"})
      assert :ok = Issues.add_dependencies(blocked, [blocker.number])

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues")

      assert %{"issues" => issues} = json_response(conn, 200)
      by_number = Map.new(issues, &{&1["number"], &1["openagents"]})

      assert %{"blocked" => true, "blocked_by" => [_one]} = by_number[blocked.number]
      assert %{"blocked" => false, "blocks" => [_one]} = by_number[blocker.number]
    end

    test "an issue without prerequisites reports an empty graph", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Ready"})

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      assert %{"openagents" => %{"blocked" => false, "blocked_by" => [], "blocks" => []}} =
               json_response(conn, 200)
    end
  end

  describe "the blocked filter" do
    test "index lists only the issues waiting on an open prerequisite", %{conn: conn} do
      {:ok, blocked} = Issues.create_issue(repository(), %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository(), %{title: "Prerequisite"})
      {:ok, _ready} = Issues.create_issue(repository(), %{title: "Ready"})
      assert :ok = Issues.add_dependencies(blocked, [blocker.number])

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?blocked=true")

      assert %{"issues" => [issue], "pagination" => %{"total" => 1}} = json_response(conn, 200)
      assert issue["title"] == "Waiting"
    end

    test "index lists the issues an agent can start now", %{conn: conn} do
      {:ok, blocked} = Issues.create_issue(repository(), %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository(), %{title: "Prerequisite"})
      {:ok, _ready} = Issues.create_issue(repository(), %{title: "Ready"})
      assert :ok = Issues.add_dependencies(blocked, [blocker.number])

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?blocked=false")

      assert %{"issues" => issues, "pagination" => %{"total" => 2}} = json_response(conn, 200)
      assert Enum.map(issues, & &1["title"]) |> Enum.sort() == ["Prerequisite", "Ready"]
    end

    test "closing the prerequisite moves the issue to the unblocked list", %{conn: conn} do
      {:ok, blocked} = Issues.create_issue(repository(), %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository(), %{title: "Prerequisite"})
      assert :ok = Issues.add_dependencies(blocked, [blocker.number])

      patch(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{blocker.number}", %{
        state: "closed"
      })

      blocked_conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?blocked=true")
      assert %{"issues" => [], "pagination" => %{"total" => 0}} = json_response(blocked_conn, 200)

      ready_conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?blocked=false")

      assert %{"issues" => [issue], "pagination" => %{"total" => 1}} =
               json_response(ready_conn, 200)

      assert issue["title"] == "Waiting"
    end

    test "index rejects a blocked value that is not a boolean", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?blocked=maybe")

      assert %{"errors" => %{"blocked" => [message]}} = json_response(conn, 422)
      assert message =~ "true or false"
    end
  end
end
