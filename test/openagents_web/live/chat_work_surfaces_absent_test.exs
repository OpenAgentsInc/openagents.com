defmodule OpenAgentsWeb.ChatWorkSurfacesAbsentTest do
  @moduledoc """
  Pins the zero-based `/chat` decision.

  The work rail, the sidebar work section, the live delegation panel, and the
  deep-work rollup header were removed from `OpenAgentsWeb.ChatLive`. The work
  and delegation records they projected are still durable, and the projections
  behind them still have their own proofs — `OpenAgents.WorkJobTest` for job
  lifecycle broadcasts, `OpenAgents.ComputerActivityTest` for the bounded
  delegation stream and its owner scoping. What these tests hold is the
  surface: a re-introduced rail, section, panel, or rollup fails here.
  """

  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest

  alias OpenAgents.{Computer, Conversations, Machines, Work}
  alias OpenAgents.Support.FakeController

  test "no work rail, no sidebar work section, and no rows for a job that ran", %{conn: conn} do
    user = github_user("chat-zero-base-work")
    conn = log_in_github_user(conn, "chat-zero-base-work")

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "Rebuild the staging index"
      })

    {:ok, running} = Work.mark_job_running(job, %{})
    {:ok, finished} = Work.finish_job(running.id, "completed")

    # The job is durable and its report landed in the transcript. Nothing below
    # is about the job going missing; it is about the surface staying quiet.
    assert finished.status == "completed"
    assert [_job] = Work.recent_jobs(conversation, 8)

    {:ok, view, _html} = live(conn, ~p"/sarah")

    refute has_element?(view, "#chat-rail")
    refute has_element?(view, "#chat-rail-toggle")
    refute has_element?(view, "#rail-work")
    refute has_element?(view, "#sidebar-work")
    refute has_element?(view, "#sidebar-job-#{job.id}")
    refute has_element?(view, "#rail-job-#{job.id}")

    # The chat column is the whole shell now: no second column beside it.
    assert has_element?(view, ".chat-shell > .app-main")
    refute has_element?(view, ".chat-shell > aside")
  end

  test "a deep-work report is an ordinary transcript message, not a rollup header",
       %{conn: conn} do
    user = github_user("chat-zero-base-rollup")
    conn = log_in_github_user(conn, "chat-zero-base-rollup")

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "Collect the release notes"
      })

    {:ok, running} = Work.mark_job_running(job, %{})
    {:ok, finished} = Work.finish_job(running.id, "completed")

    {:ok, view, _html} = live(conn, ~p"/sarah")

    # The report is in the transcript and still marks itself as one.
    assert has_element?(view, "#messages-#{finished.report_message_id}.message-row--report")
    refute has_element?(view, "#job-rollup-messages-#{finished.report_message_id}")
    refute has_element?(view, ".job-rollup")
  end

  test "a streamed delegation renders nothing and pushes no chunk to the client",
       %{conn: conn} do
    %{conn: conn, machine: machine} = delegation_owner(conn, "chat-zero-base-live", "quiet-box")
    {:ok, view, _html} = live(conn, ~p"/sarah")

    caller = start_delegation(machine, "claude")
    FakeController.chunk(caller.pid, caller.request_id, "hello from the machine")

    # `:sys.get_state/1` flushes every message the LiveView had already been
    # sent, so this is a settled view rather than a race with the broadcast.
    _state = :sys.get_state(view.pid)

    refute has_element?(view, "#delegation-rail")
    refute has_element?(view, "#delegation-inline")
    refute has_element?(view, "#delegation-live")
    refute has_element?(view, "#cancel-delegation")
    refute has_element?(view, ".delegation-summary")
    refute render(view) =~ "hello from the machine"
    refute_push_event(view, "delegation:chunk", %{})

    FakeController.exit(caller.pid, caller.request_id, %{
      "status" => "completed",
      "stop_reason" => "end_turn",
      "truncated" => false,
      "duration_ms" => 12_000
    })

    assert {:ok, _result} = Task.await(caller.task)

    _settled = :sys.get_state(view.pid)
    refute has_element?(view, "#delegation-terminal")
    refute render(view) =~ "end_turn"
  end

  test "another account's conversation never renders the delegation", %{conn: conn} do
    %{conn: owner_conn, machine: machine} =
      delegation_owner(conn, "chat-zero-base-owner", "owned-box")

    other_conn = log_in_github_user(build_conn(), "chat-zero-base-outsider")
    {:ok, owner_view, _owner_html} = live(owner_conn, ~p"/sarah")
    {:ok, other_view, _other_html} = live(other_conn, ~p"/sarah")

    caller = start_delegation(machine, "claude")
    FakeController.chunk(caller.pid, caller.request_id, "owner-only progress")

    _owner_state = :sys.get_state(owner_view.pid)
    _other_state = :sys.get_state(other_view.pid)

    # The projection's topic is keyed by the owner's conversation, so the other
    # account's LiveView structurally never receives the stream
    # (`OpenAgents.ComputerActivityTest` proves the scoping itself). The chat
    # surface states no delegation for anyone, which is what is held here: the
    # streamed text reaches neither transcript.
    refute render(owner_view) =~ "owner-only progress"
    refute render(other_view) =~ "owner-only progress"
    refute has_element?(other_view, "#delegation-rail")
    refute has_element?(other_view, "#delegation-inline")
    refute has_element?(other_view, "#delegation-live")
    refute_push_event(other_view, "delegation:chunk", %{})

    FakeController.exit(caller.pid, caller.request_id, %{
      "status" => "completed",
      "stop_reason" => "end_turn",
      "truncated" => false,
      "duration_ms" => 1
    })

    assert {:ok, _result} = Task.await(caller.task)
  end

  # Logs the account in, ensures its one conversation exists, and pairs one
  # machine so a delegation can target it.
  defp delegation_owner(conn, key, machine_name) do
    user = github_user(key)
    conn = log_in_github_user(conn, key)
    {:ok, _conversation} = Conversations.ensure_conversation(user)
    %{conn: conn, user: user, machine: paired_machine(user, machine_name)}
  end

  defp paired_machine(user, name) do
    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => name,
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => []
      })

    {:ok, machine} = Machines.approve_pairing(user, code)
    machine
  end

  # Connects a fake controller for the machine and starts the delegation in a
  # task; the script hands the request correlation back so the test drives the
  # stream itself.
  defp start_delegation(machine, agent_id) do
    test_pid = self()

    start_supervised!(
      {FakeController,
       machine_id: machine.id,
       script: fn {:agent, request_id, _payload, caller_pid} ->
         send(test_pid, {:delegation_request, machine.id, request_id, caller_pid})
       end},
      id: {FakeController, machine.id}
    )

    task =
      Task.async(fn ->
        Computer.request_agent(machine.id, %{"agent_id" => agent_id, "prompt" => "work"}, 5_000)
      end)

    machine_id = machine.id
    assert_receive {:delegation_request, ^machine_id, request_id, caller_pid}
    %{task: task, request_id: request_id, pid: caller_pid}
  end
end
