defmodule OpenAgentsWeb.IssueStartWorkLiveTest do
  @moduledoc """
  Stage 2 of `#10`: start bounded agent work from the issue that describes it.

  The admission already existed and is not duplicated here. What these tests
  hold is the issue-side entry point: who is offered it, what it reads from the
  issue rather than from free text, and that every refusal the context returns
  reaches the person as itself.
  """
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Computer
  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Issues
  alias OpenAgents.Machines
  alias OpenAgents.Repo

  setup %{conn: conn} do
    repository = OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
    user = github_user("issue-work-starter")
    {:ok, _membership} = OpenAgents.Repositories.add_member(repository, user, "owner")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})

    {:ok, issue} =
      Issues.create_issue(repository, %{title: "Ship the join", body: "Bind the receipts."})

    %{conn: conn, user: user, repository: repository, issue: issue}
  end

  defp path(issue), do: ~p"/OpenAgentsInc/openagents.com/issues/#{issue.number}"

  describe "who is offered the control" do
    test "a maintainer with no connected computer is told why, not shown a form", %{
      conn: conn,
      issue: issue
    } do
      {:ok, view, _html} = live(conn, path(issue))

      assert has_element?(view, "#issue-work")
      assert has_element?(view, "#issue-work-unavailable")
      refute has_element?(view, "#issue-work-form")
    end

    test "a maintainer with a connected computer is offered the form", context do
      connected_computer(context.user)

      {:ok, view, _html} = live(context.conn, path(context.issue))

      assert has_element?(view, "#issue-work-form")
      assert has_element?(view, "#issue-work-start")
    end

    test "an anonymous reader is offered nothing and cannot reach the event", context do
      connected_computer(context.user)

      {:ok, view, _html} = live(build_conn(), path(context.issue))

      refute has_element?(view, "#issue-work")
      refute has_element?(view, "#issue-work-form")

      render_hook(view, "start_work", %{"work" => %{}})

      assert render(view) =~ "You can no longer start work on this issue."
      assert Repo.aggregate(Assignment, :count) == 0
    end

    test "a signed-in reader without write authority is refused", context do
      connected_computer(context.user)
      reader = github_user("issue-work-reader")
      reader_conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => reader.id})

      {:ok, view, _html} = live(reader_conn, path(context.issue))

      refute has_element?(view, "#issue-work")

      render_hook(view, "start_work", %{"work" => %{}})

      assert Repo.aggregate(Assignment, :count) == 0
    end
  end

  describe "starting the work" do
    test "the attempt appears on the timeline without a reload", context do
      machine = connected_computer(context.user)

      {:ok, view, _html} = live(context.conn, path(context.issue))

      html =
        view
        |> form("#issue-work-form", %{
          "work" => %{
            "computer_id" => machine.id,
            "agent_id" => "codex",
            "cwd" => "/work",
            "branch" => "agent/issue-#{context.issue.number}"
          }
        })
        |> render_submit()

      assert html =~ "Work started on"
      assert html =~ "started work on a computer, on branch agent/issue-#{context.issue.number}"

      assert %Assignment{} =
               assignment = Repo.get_by(Assignment, issue_id: context.issue.id)

      assert assignment.branch == "agent/issue-#{context.issue.number}"
      assert assignment.repository_id == context.repository.id
      assert assignment.machine_id == machine.id
      assert assignment.requesting_principal["id"] == context.user.id
    end

    test "the objective is read from the issue rather than typed beside it", context do
      machine = connected_computer(context.user)

      {:ok, view, _html} = live(context.conn, path(context.issue))

      view
      |> form("#issue-work-form", %{
        "work" => %{
          "computer_id" => machine.id,
          "agent_id" => "codex",
          "cwd" => "/work",
          "branch" => "agent/objective"
        }
      })
      |> render_submit()

      assert %Assignment{work_job_id: job_id} =
               Repo.get_by(Assignment, issue_id: context.issue.id)

      assert job_id

      job = Repo.get!(OpenAgents.Work.Job, job_id)
      prompt = job.delegation["prompt"]

      assert prompt =~ "issue ##{context.issue.number}"
      assert prompt =~ "Ship the join"
      assert prompt =~ "Bind the receipts."
      assert prompt =~ "agent/objective"
    end

    test "a protected branch is refused by name and starts nothing", context do
      machine = connected_computer(context.user)

      {:ok, view, _html} = live(context.conn, path(context.issue))

      html =
        view
        |> form("#issue-work-form", %{
          "work" => %{
            "computer_id" => machine.id,
            "agent_id" => "codex",
            "cwd" => "/work",
            "branch" => "main"
          }
        })
        |> render_submit()

      assert html =~ "That branch is protected"
      assert Repo.aggregate(Assignment, :count) == 0
    end

    # The working directory and the agent are chosen from what the computer
    # itself declared, never taken from the request. A crafted event asking for
    # somewhere else does not reach the admission with that value at all.
    test "a working directory the computer never declared is never forwarded", context do
      machine = connected_computer(context.user)

      {:ok, view, _html} = live(context.conn, path(context.issue))

      render_hook(view, "start_work", %{
        "work" => %{
          "computer_id" => machine.id,
          "agent_id" => "impostor",
          "cwd" => "/elsewhere",
          "branch" => "agent/outside"
        }
      })

      assert %Assignment{work_job_id: job_id} =
               Repo.get_by(Assignment, issue_id: context.issue.id)

      job = Repo.get!(OpenAgents.Work.Job, job_id)

      assert job.delegation["cwd"] == "/work"
      assert job.delegation["agent_id"] == "codex"
    end
  end

  describe "one attempt at a time" do
    test "a live attempt replaces the form with the branch it is running on", context do
      machine = connected_computer(context.user)
      live_attempt(context, machine, "agent/already-running")

      {:ok, view, _html} = live(context.conn, path(context.issue))

      assert has_element?(view, "#issue-work-live")
      refute has_element?(view, "#issue-work-form")
      assert render(view) =~ "agent/already-running"
    end

    test "starting a second attempt is refused with the live one named", context do
      machine = connected_computer(context.user)

      {:ok, view, _html} = live(context.conn, path(context.issue))

      live_attempt(context, machine, "agent/already-running")

      render_hook(view, "start_work", %{
        "work" => %{
          "computer_id" => machine.id,
          "agent_id" => "codex",
          "cwd" => "/work",
          "branch" => "agent/second"
        }
      })

      html = render(view)
      assert html =~ "Work is already running on this issue"
      assert Repo.aggregate(Assignment, :count) == 1
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp connected_computer(user) do
    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => "workstation",
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => ["/work"]
      })

    {:ok, machine} = Machines.approve_pairing(user, code)
    {:ok, machine} = Machines.store_probe(machine, %{"acp_agents" => [%{"id" => "codex"}]})
    {:ok, _owner} = Computer.register(machine.id)
    on_exit(fn -> Computer.unregister(machine.id) end)
    machine
  end

  defp live_attempt(%{repository: repository, issue: issue, user: user}, machine, branch) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Assignment{}
    |> Assignment.changeset(%{
      target_kind: "computer",
      machine_id: machine.id,
      repository_id: repository.id,
      issue_id: issue.id,
      requesting_principal: %{"type" => "user", "id" => user.id},
      branch: branch,
      state: "running",
      admitted_at: now,
      started_at: now,
      deadline_at: DateTime.add(now, 3600, :second)
    })
    |> Repo.insert!()
  end
end
