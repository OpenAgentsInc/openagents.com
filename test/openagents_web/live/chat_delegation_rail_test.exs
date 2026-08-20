defmodule OpenAgentsWeb.ChatDelegationRailTest do
  use OpenAgentsWeb.SarahConnCase
  import Phoenix.LiveViewTest

  alias OpenAgents.{Computer, Conversations, Machines}
  alias OpenAgents.Support.FakeController

  # Mirrors the projection's per-event byte cap; four such chunks reach the
  # 65,536-byte cumulative cap.
  @maximum_event_bytes 16_384

  test "no delegation means no rail and no inline panel", %{conn: conn} do
    conn = log_in_github_user(conn, "delegation-idle-browser")
    {:ok, view, _html} = live(conn, ~p"/chat")

    refute has_element?(view, "#delegation-rail")
    refute has_element?(view, "#delegation-inline")
  end

  test "a streamed delegation renders the rail, the inline panel, and pushes chunks",
       %{conn: conn} do
    %{conn: conn, machine: machine} =
      delegation_owner(conn, "delegation-live-browser", "rail-box")

    {:ok, view, _html} = live(conn, ~p"/chat")

    caller = start_delegation(machine, "claude")
    FakeController.chunk(caller.pid, caller.request_id, "hello from the machine")

    # The chunk rides a push event to the log hooks, never an assign; once it
    # arrives, the start event has necessarily been applied too.
    assert_push_event(view, "delegation:chunk", %{text: "hello from the machine"}, 1_000)

    # Desktop rail: header facts, running state, the hook-owned log and clock.
    assert has_element?(view, "#delegation-rail #delegation-live[data-status='running']")
    assert has_element?(view, "#delegation-live .delegation-live__machine", "rail-box")
    assert has_element?(view, "#delegation-live .delegation-live__subject", "claude")
    assert has_element?(view, ~s(#cancel-delegation[aria-label="Cancel delegation"]))
    assert has_element?(view, "#delegation-live div.delegation-log[phx-update='ignore']")
    assert has_element?(view, "#delegation-live time[data-started-at]")

    assert has_element?(
             view,
             ~s(#delegation-rail-toggle[aria-label="Toggle delegation panel"])
           )

    # Collapse is a server assign so it survives the rail re-rendering on every
    # streamed chunk: the toggle flips it and it stays flipped.
    assert has_element?(view, ~s(#delegation-rail[data-collapsed="false"]))
    view |> element("#delegation-rail-toggle") |> render_click()
    assert has_element?(view, ~s(#delegation-rail[data-collapsed="true"]))
    assert has_element?(view, ~s(#delegation-rail-toggle[aria-expanded="false"]))
    view |> element("#delegation-rail-toggle") |> render_click()
    assert has_element?(view, ~s(#delegation-rail[data-collapsed="false"]))

    # Narrow-viewport variant: the same projection as an expandable
    # event-header section at the transcript tail, live log inside.
    assert has_element?(view, "#delegation-inline #delegation-inline-header.event-header")
    assert has_element?(view, "#delegation-inline div.delegation-log")

    FakeController.exit(caller.pid, caller.request_id, %{
      "status" => "completed",
      "stop_reason" => "end_turn",
      "session_id" => "acp-rail-1",
      "truncated" => false,
      "duration_ms" => 12_000
    })

    assert {:ok, _result} = Task.await(caller.task)

    # Terminal: the panel collapses to a typed summary line with the status
    # word, stop reason, and duration, plus a dismiss control.
    assert eventually(fn -> has_element?(view, "#delegation-terminal") end)
    refute has_element?(view, "#delegation-live")
    assert has_element?(view, "#delegation-terminal .delegation-summary__meta", "SUCCEEDED")
    assert has_element?(view, "#delegation-terminal .delegation-summary__meta", "end_turn")
    assert has_element?(view, "#delegation-terminal .delegation-summary__meta", "12s")
    assert has_element?(view, ~s(#delegation-dismiss[aria-label="Dismiss"]))

    # Dismissing clears the whole ephemeral projection; the durable event
    # header in the transcript remains the record.
    view |> element("#delegation-dismiss") |> render_click()
    refute has_element?(view, "#delegation-rail")
    refute has_element?(view, "#delegation-inline")
  end

  test "the capped stream renders an explicit truncation marker", %{conn: conn} do
    %{conn: conn, machine: machine} =
      delegation_owner(conn, "delegation-truncation-browser", "cap-box")

    {:ok, view, _html} = live(conn, ~p"/chat")

    caller = start_delegation(machine, "claude")
    filler = String.duplicate("a", @maximum_event_bytes)

    for _fill <- 1..4, do: FakeController.chunk(caller.pid, caller.request_id, filler)
    FakeController.chunk(caller.pid, caller.request_id, "beyond the cap")

    assert eventually(fn ->
             has_element?(view, "#delegation-rail .delegation-truncated", "TRUNCATED")
           end)

    FakeController.exit(caller.pid, caller.request_id, %{
      "status" => "completed",
      "stop_reason" => "end_turn",
      "truncated" => true,
      "duration_ms" => 5
    })

    assert {:ok, _result} = Task.await(caller.task)
  end

  test "a newer delegation supersedes the panel; the older collapses to a summary",
       %{conn: conn} do
    %{conn: conn, user: user, machine: first_machine} =
      delegation_owner(conn, "delegation-supersede-browser", "first-box")

    second_machine = paired_machine(user, "second-box")
    {:ok, view, _html} = live(conn, ~p"/chat")

    first = start_delegation(first_machine, "claude")
    FakeController.chunk(first.pid, first.request_id, "first delegation working")
    assert_push_event(view, "delegation:chunk", %{text: "first delegation working"}, 1_000)
    assert has_element?(view, "#delegation-live .delegation-live__machine", "first-box")

    second = start_delegation(second_machine, "codex")
    FakeController.chunk(second.pid, second.request_id, "second delegation working")
    assert_push_event(view, "delegation:chunk", %{text: "second delegation working"}, 1_000)

    # One live panel: the newest delegation owns it; the superseded one is a
    # bounded summary line beneath.
    assert has_element?(view, "#delegation-live .delegation-live__machine", "second-box")
    refute has_element?(view, "#delegation-live .delegation-live__machine", "first-box")
    assert has_element?(view, ".delegation-summary--superseded", "first-box")

    for caller <- [first, second] do
      FakeController.exit(caller.pid, caller.request_id, %{
        "status" => "completed",
        "stop_reason" => "end_turn",
        "truncated" => false,
        "duration_ms" => 1
      })

      assert {:ok, _result} = Task.await(caller.task)
    end

    # The superseded summary picks up its own terminal status.
    assert eventually(fn ->
             has_element?(
               view,
               ".delegation-summary--superseded .delegation-summary__meta",
               "SUCCEEDED"
             )
           end)
  end

  test "another account's conversation never renders the delegation", %{conn: conn} do
    %{conn: owner_conn, machine: machine} =
      delegation_owner(conn, "delegation-owner-browser", "owned-box")

    other_conn = log_in_github_user(build_conn(), "delegation-outsider-browser")
    {:ok, owner_view, _owner_html} = live(owner_conn, ~p"/chat")
    {:ok, other_view, _other_html} = live(other_conn, ~p"/chat")

    caller = start_delegation(machine, "claude")
    FakeController.chunk(caller.pid, caller.request_id, "owner-only progress")
    assert_push_event(owner_view, "delegation:chunk", %{text: "owner-only progress"}, 1_000)
    assert has_element?(owner_view, "#delegation-rail")

    # The topic is scoped to the owner's conversation, so the other account's
    # LiveView structurally never receives the stream.
    refute has_element?(other_view, "#delegation-rail")
    refute has_element?(other_view, "#delegation-inline")
    refute render(other_view) =~ "owner-only progress"

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

  defp eventually(assertion, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(assertion, deadline)
  end

  defp do_eventually(assertion, deadline) do
    if assertion.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        receive do
          _message -> :ok
        after
          10 -> :ok
        end

        do_eventually(assertion, deadline)
      end
    end
  end
end
