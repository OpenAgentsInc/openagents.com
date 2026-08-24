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

      body = assert_api_error(response, 401, "unauthenticated")
      assert body["error"] == "invalid_api_token"
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

  # The attempt record is `forge_assignments`. Writing one directly keeps this
  # test about the projection rather than about the admission path that
  # creates it, which `OpenAgents.Forge.AssignmentTest` already covers.
  # The evidence chain, built through the same two directions production uses:
  # #130's closing reference claims the commit, and the receipts bind to it.
  defp record_evidence(issue, sha) do
    repository = repository()

    user =
      Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: "evidence-#{System.unique_integer([:positive])}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })
      |> elem(1)

    %OpenAgents.Issues.ClosingReference{}
    |> OpenAgents.Issues.ClosingReference.changeset(%{
      repository_id: repository.id,
      issue_id: issue.id,
      commit_sha: sha,
      principal: "user:#{user.id}",
      verb: "closes",
      closed: true
    })
    |> Repo.insert!()

    build =
      %OpenAgents.Forge.BuildReceipt{}
      |> OpenAgents.Forge.BuildReceipt.start_changeset(%{
        repo: repository.storage_key,
        sha: sha,
        target_id: Ecto.UUID.generate()
      })
      |> Ecto.Changeset.put_change(:status, "complete")
      |> Repo.insert!()

    deploy =
      %OpenAgents.Forge.DeployReceipt{}
      |> OpenAgents.Forge.DeployReceipt.changeset(%{
        repo: repository.storage_key,
        sha: sha,
        target_id: Ecto.UUID.generate(),
        result: "live",
        deployment_type: "direct_load"
      })
      |> Repo.insert!()

    OpenAgents.Issues.Evidence.record_build(build)
    OpenAgents.Issues.Evidence.record_deploy(deploy)
  end

  defp record_attempt(issue, branch, offset_seconds, overrides) do
    user =
      Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: "attempt-#{System.unique_integer([:positive])}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })
      |> elem(1)

    {:ok, %{code: code}} =
      OpenAgents.Machines.start_pairing(%{
        "name" => branch,
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => []
      })

    {:ok, machine} = OpenAgents.Machines.approve_pairing(user, code)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    admitted_at = DateTime.add(now, offset_seconds, :second)
    state = Map.get(overrides, :state, "running")

    %OpenAgents.Forge.Assignment{}
    |> OpenAgents.Forge.Assignment.changeset(
      Map.merge(
        %{
          target_kind: "computer",
          machine_id: machine.id,
          repository_id: repository().id,
          issue_id: issue.id,
          requesting_principal: %{"type" => "user", "id" => user.id},
          branch: branch,
          state: state,
          admitted_at: admitted_at,
          started_at: admitted_at,
          finished_at:
            if(state in OpenAgents.Forge.Assignment.terminal_states(), do: admitted_at),
          deadline_at: DateTime.add(admitted_at, 3600, :second)
        },
        overrides
      )
    )
    |> Repo.insert!()
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

    test "an issue nobody has worked reports no attempts, not a missing field", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Unworked"})

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      assert %{"openagents" => %{"work" => []}} = json_response(conn, 200)
    end

    test "show carries every recorded execution attempt, oldest first", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Worked twice"})
      sha = String.duplicate("cd", 20)

      record_attempt(issue, "agent/first", -600, %{state: "failed", failure_reason: "timeout"})
      record_attempt(issue, "agent/second", -60, %{state: "completed", terminal_commit: sha})

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      assert %{"openagents" => %{"work" => [first, second]}} = json_response(conn, 200)

      assert first["branch"] == "agent/first"
      assert first["state"] == "failed"
      assert first["failure_reason"] == "timeout"
      assert is_nil(first["commit"])

      assert second["branch"] == "agent/second"
      assert second["state"] == "completed"
      assert second["commit"] == sha
      assert second["target"] == "computer"
    end

    test "an attempt never carries the prompt, conversation, or credential", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Bounded"})
      record_attempt(issue, "agent/bounded", -30, %{})

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      assert %{"openagents" => %{"work" => [attempt]}} = json_response(conn, 200)

      assert Enum.sort(Map.keys(attempt)) == [
               "branch",
               "commit",
               "failure_reason",
               "finished_at",
               "id",
               "started_at",
               "state",
               "target"
             ]
    end

    test "index carries the attempts for every issue on the page", %{conn: conn} do
      {:ok, worked} = Issues.create_issue(repository(), %{title: "Worked"})
      {:ok, _idle} = Issues.create_issue(repository(), %{title: "Idle"})
      record_attempt(worked, "agent/page", -45, %{})

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues")

      assert %{"issues" => issues} = json_response(conn, 200)
      by_title = Map.new(issues, &{&1["title"], &1["openagents"]["work"]})

      assert [%{"branch" => "agent/page"}] = by_title["Worked"]
      assert by_title["Idle"] == []
    end
  end

  describe "the issue evidence chain" do
    test "an issue nothing has evaluated reports no evidence, not a missing field", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Unevaluated"})

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      assert %{"openagents" => %{"evidence" => []}} = json_response(conn, 200)
    end

    test "show carries the receipts bound to the commit the issue claims", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Shipped"})
      sha = String.duplicate("9a", 20)
      record_evidence(issue, sha)

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      assert %{"openagents" => %{"evidence" => [build, deploy]}} = json_response(conn, 200)

      assert build["family"] == "build"
      assert build["commit"] == sha
      assert build["plane"] == "forge"
      assert build["result"] == "complete"
      assert build["source"] == "closing_reference"

      assert deploy["family"] == "deployment"
      assert deploy["environment"] == "fleet"
      assert deploy["result"] == "live"
    end

    test "an evidence edge never carries the actor or the attempt", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Bounded evidence"})
      record_evidence(issue, String.duplicate("7b", 20))

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      assert %{"openagents" => %{"evidence" => [entry | _]}} = json_response(conn, 200)

      assert Enum.sort(Map.keys(entry)) == [
               "commit",
               "environment",
               "family",
               "id",
               "plane",
               "receipt_id",
               "recorded_at",
               "result",
               "source"
             ]
    end

    test "index carries the evidence for every issue on the page", %{conn: conn} do
      {:ok, shipped} = Issues.create_issue(repository(), %{title: "Evidenced"})
      {:ok, _idle} = Issues.create_issue(repository(), %{title: "Unevidenced"})
      record_evidence(shipped, String.duplicate("4c", 20))

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues")

      assert %{"issues" => issues} = json_response(conn, 200)
      by_title = Map.new(issues, &{&1["title"], &1["openagents"]["evidence"]})

      assert [%{"family" => "build"}, %{"family" => "deployment"}] = by_title["Evidenced"]
      assert by_title["Unevidenced"] == []
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

  describe "the progress extension field" do
    test "show reports what a board says about the issue", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Underway"})
      place(repository(), issue, "In Progress")

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      assert %{"openagents" => %{"progress" => "in_progress"}} = json_response(conn, 200)
    end

    test "an issue on no board has not started", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Queued"})

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}")

      assert %{"openagents" => %{"progress" => "to_do"}} = json_response(conn, 200)
    end

    test "closing the issue finishes it", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Underway"})
      place(repository(), issue, "In Progress")

      conn =
        patch(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}", %{
          state: "closed"
        })

      assert %{"openagents" => %{"progress" => "done"}} = json_response(conn, 200)
    end

    test "index carries progress for every issue on the page", %{conn: conn} do
      {:ok, started} = Issues.create_issue(repository(), %{title: "Underway"})
      {:ok, queued} = Issues.create_issue(repository(), %{title: "Queued"})
      place(repository(), started, "In Progress")

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues")

      assert %{"issues" => issues} = json_response(conn, 200)
      by_number = Map.new(issues, &{&1["number"], &1["openagents"]["progress"]})

      assert by_number[started.number] == "in_progress"
      assert by_number[queued.number] == "to_do"
    end

    test "a GitHub-shaped client sees its own keys unchanged", %{conn: conn} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Underway"})
      place(repository(), issue, "In Progress")

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}")
      body = json_response(conn, 200)

      assert body["state"] == "open"
      assert body["title"] == "Underway"

      # Every extension lives inside `openagents`; nothing leaks into the
      # GitHub-shaped key set, which is what a GitHub client reads.
      assert Enum.sort(Map.keys(body) -- ["openagents"]) ==
               Enum.sort(~w(
                 assignees body closed_at comments created_at html_url id labels locked
                 milestone node_id number state state_reason title updated_at url user
               ))
    end
  end

  describe "the progress filter" do
    test "index lists the issues a board has started", %{conn: conn} do
      {:ok, started} = Issues.create_issue(repository(), %{title: "Underway"})
      {:ok, _queued} = Issues.create_issue(repository(), %{title: "Queued"})
      place(repository(), started, "In Progress")

      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?progress=in_progress")

      assert %{"issues" => [issue], "pagination" => %{"total" => 1}} = json_response(conn, 200)
      assert issue["title"] == "Underway"
      assert issue["openagents"]["progress"] == "in_progress"
    end

    test "the filter and the field agree for every issue on the page", %{conn: conn} do
      {:ok, started} = Issues.create_issue(repository(), %{title: "Underway"})
      {:ok, _queued} = Issues.create_issue(repository(), %{title: "Queued"})
      {:ok, _closed} = Issues.create_issue(repository(), %{title: "Finished", state: "closed"})
      place(repository(), started, "In Progress")

      for value <- ["to_do", "in_progress", "done"] do
        conn =
          get(
            conn,
            ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?state=all&progress=#{value}"
          )

        for issue <- json_response(conn, 200)["issues"] do
          assert issue["openagents"]["progress"] == value
        end
      end
    end

    test "a private board never moves an issue into an outsider's started list" do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Tracked privately"})
      private = repository_fixture(%{visibility: "private"})
      place(private, issue, "In Progress")

      anonymous =
        get(
          build_conn(),
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}"
        )

      assert %{"openagents" => %{"progress" => "to_do"}} = json_response(anonymous, 200)

      listed =
        get(
          build_conn(),
          ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?progress=in_progress"
        )

      assert %{"issues" => [], "pagination" => %{"total" => 0}} = json_response(listed, 200)
    end

    test "index rejects a progress value outside the published enum", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?progress=doing")

      assert %{"errors" => %{"progress" => [message]}} = json_response(conn, 422)
      assert message =~ "to_do"
    end
  end

  describe "pull requests in the issue list" do
    setup do
      source = OpenAgents.AccountsFixtures.repository_fixture()
      {:ok, proposal} = Issues.create_issue(repository(), %{title: "Proposes a change"})

      pull_request =
        %OpenAgents.PullRequests.PullRequest{}
        |> OpenAgents.PullRequests.PullRequest.changeset(%{
          repository_id: repository().id,
          issue_id: proposal.id,
          head_repository_id: source.id,
          head_ref: "feature",
          head_sha: String.duplicate("a", 40),
          base_ref: "main",
          base_sha: String.duplicate("b", 40),
          draft: false
        })
        |> Repo.insert!()

      {:ok, plain} = Issues.create_issue(repository(), %{title: "Plain issue"})

      %{plain: plain, proposal: proposal, pull_request: pull_request}
    end

    test "index returns both kinds by default, the way GitHub's does", %{
      conn: conn,
      plain: plain,
      proposal: proposal
    } do
      %{"issues" => issues} =
        conn
        |> get(~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues")
        |> json_response(200)

      numbers = Enum.map(issues, & &1["number"])
      assert plain.number in numbers
      assert proposal.number in numbers
    end

    test "a pull-request-backed entry carries GitHub's pull_request marker", %{
      conn: conn,
      proposal: proposal
    } do
      %{"issues" => issues} =
        conn
        |> get(~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues")
        |> json_response(200)

      entry = Enum.find(issues, &(&1["number"] == proposal.number))

      assert entry["draft"] == false
      assert entry["pull_request"]["html_url"] =~ "/pulls/#{proposal.number}"
      assert entry["pull_request"]["url"] =~ "/api/v3/repos/OpenAgentsInc/openagents.com/pulls/"
      assert entry["pull_request"]["merged_at"] == nil
    end

    test "a plain issue carries neither key, so presence is the fact", %{
      conn: conn,
      plain: plain
    } do
      entry =
        conn
        |> get(~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{plain.number}")
        |> json_response(200)

      refute Map.has_key?(entry, "pull_request")
      refute Map.has_key?(entry, "draft")
    end

    test "the show endpoint marks a pull request too", %{conn: conn, proposal: proposal} do
      entry =
        conn
        |> get(~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/#{proposal.number}")
        |> json_response(200)

      assert entry["pull_request"]["html_url"] =~ "/pulls/#{proposal.number}"
    end

    test "type=issue lists issues without the pull requests", %{
      conn: conn,
      plain: plain,
      proposal: proposal
    } do
      %{"issues" => issues} =
        conn
        |> get(~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?type=issue")
        |> json_response(200)

      numbers = Enum.map(issues, & &1["number"])
      assert plain.number in numbers
      refute proposal.number in numbers
    end

    test "type=pull_request lists only the pull requests", %{
      conn: conn,
      plain: plain,
      proposal: proposal
    } do
      %{"issues" => issues} =
        conn
        |> get(~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?type=pull_request")
        |> json_response(200)

      numbers = Enum.map(issues, & &1["number"])
      assert proposal.number in numbers
      refute plain.number in numbers
    end

    test "index rejects a type outside the published enum", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues?type=proposal")

      assert %{"errors" => %{"type" => [message]}} = json_response(conn, 422)
      assert message =~ "pull_request"
    end
  end

  defp place(board_repository, issue, column) do
    {:ok, project} =
      OpenAgents.Projects.create_project(board_repository, %{
        title: "Board",
        owner: "OpenAgents"
      })

    {:ok, item} =
      OpenAgents.ProjectItems.create_project_item(board_repository, %{
        project_id: project.id,
        issue_id: issue.id,
        issue_repository_id: issue.repository_id,
        values: %{"Status" => column}
      })

    item
  end
end
