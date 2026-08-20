defmodule OpenAgentsWeb.ComputerChannelTest do
  use OpenAgents.SarahDataCase, async: false
  @moduletag :skip

  import Phoenix.ChannelTest
  import OpenAgentsWeb.SarahConnCase, only: [github_user: 1]

  @endpoint OpenAgentsWeb.Endpoint

  alias OpenAgents.Computer
  alias OpenAgents.Machines

  defp paired_machine(key) do
    {:ok, %{pairing: pairing, code: code, poll_secret: poll_secret}} =
      Machines.start_pairing(%{
        "name" => "channel-box-#{key}",
        "tier" => "probe",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => ["/home/someone/code"]
      })

    owner = github_user("channel-#{key}")
    {:ok, machine} = Machines.approve_pairing(owner, code)
    {:ok, %{token: token}} = Machines.claim_pairing(pairing.id, poll_secret)
    %{owner: owner, machine: machine, token: token}
  end

  test "socket rejects bad tokens and channel rejects foreign machines" do
    %{machine: machine, token: token} = paired_machine("auth")

    assert :error = connect(OpenAgentsWeb.ControllerSocket, %{"token" => "smct_wrong"})
    assert :error = connect(OpenAgentsWeb.ControllerSocket, %{})

    {:ok, socket} = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})

    assert {:error, %{"reason" => "machine_mismatch"}} =
             subscribe_and_join(socket, "computer:#{Ecto.UUID.generate()}", %{})

    assert {:ok, %{"protocol" => "sarah.computer.v1"}, _joined} =
             subscribe_and_join(socket, "computer:#{machine.id}", %{})
  end

  test "revoked machines cannot join" do
    %{owner: owner, machine: machine, token: token} = paired_machine("revoked-join")
    {:ok, _revoked} = Machines.revoke_machine(owner, machine.id)

    assert :error = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})
  end

  test "hello stores the bounded probe report" do
    %{machine: machine, token: token} = paired_machine("hello")
    {:ok, socket} = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})
    {:ok, _reply, joined} = subscribe_and_join(socket, "computer:#{machine.id}", %{})

    ref =
      push(joined, "hello", %{"agent_version" => "0.1.0", "probe" => %{"platform" => "linux"}})

    assert_reply ref, :ok, %{"machine" => %{"id" => _id}}

    {:ok, stored} = Machines.get_machine(machine.user_id, machine.id)
    assert stored.last_probe == %{"platform" => "linux"}

    oversized = push(joined, "hello", %{"probe" => %{"blob" => String.duplicate("a", 70_000)}})
    assert_reply oversized, :error, %{"reason" => "payload_too_large"}
  end

  test "probe requests are correlated end-to-end through the registry" do
    %{machine: machine, token: token} = paired_machine("probe")
    {:ok, socket} = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})
    {:ok, _reply, joined} = subscribe_and_join(socket, "computer:#{machine.id}", %{})

    assert Computer.online?(machine.id)

    caller = Task.async(fn -> Computer.request_probe(machine.id) end)

    assert_push "probe", %{"request_id" => request_id}

    push(joined, "probe_result", %{
      "request_id" => request_id,
      "probe" => %{"platform" => "linux", "coding_agents" => []}
    })

    assert {:ok, %{"platform" => "linux"}} = Task.await(caller)
  end

  test "refused probes surface as typed errors" do
    %{machine: machine, token: token} = paired_machine("refused")
    {:ok, socket} = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})
    {:ok, _reply, joined} = subscribe_and_join(socket, "computer:#{machine.id}", %{})

    caller = Task.async(fn -> Computer.request_probe(machine.id) end)

    assert_push "probe", %{"request_id" => request_id}
    push(joined, "probe_refused", %{"request_id" => request_id})

    assert {:error, :machine_refused} = Task.await(caller)
  end

  test "offline machines return a typed error without blocking" do
    %{machine: machine} = paired_machine("offline")
    refute Computer.online?(machine.id)
    assert {:error, :machine_offline} = Computer.request_probe(machine.id)
  end

  test "run requests stream chunks and finish with the exit payload" do
    %{machine: machine, token: token} = paired_machine("run")
    {:ok, socket} = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})
    {:ok, _reply, joined} = subscribe_and_join(socket, "computer:#{machine.id}", %{})

    caller =
      Task.async(fn ->
        Computer.request_run(machine.id, %{"argv" => ["git", "status"]}, 5_000)
      end)

    assert_push "run", %{"request_id" => request_id, "argv" => ["git", "status"]}

    push(joined, "chunk", %{"request_id" => request_id, "text" => "On branch main\n"})

    push(joined, "exit", %{
      "request_id" => request_id,
      "status" => "completed",
      "exit_code" => 0,
      "truncated" => false,
      "duration_ms" => 12
    })

    assert {:ok, result} = Task.await(caller)
    assert result["status"] == "completed"
    assert result["exit_code"] == 0
    assert result["output"] == "On branch main\n"
  end

  test "a mid-stream session frame reaches the caller's on_session callback (M2)" do
    %{machine: machine, token: token} = paired_machine("agent-session")
    {:ok, socket} = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})
    {:ok, _reply, joined} = subscribe_and_join(socket, "computer:#{machine.id}", %{})

    test_pid = self()

    caller =
      Task.async(fn ->
        Computer.request_agent(
          machine.id,
          %{"agent_id" => "claude", "prompt" => "do a thing"},
          5_000,
          on_session: fn session_id -> send(test_pid, {:on_session, session_id}) end
        )
      end)

    assert_push "agent", %{"request_id" => request_id}

    # The controller reports the ACP session id as soon as session/new returns.
    push(joined, "session", %{"request_id" => request_id, "session_id" => "acp-sess-42"})

    # The callback fires mid-stream (before the terminal exit) — this is what
    # lets the delegation checkpoint the session id in Ra for re-attach.
    assert_receive {:on_session, "acp-sess-42"}, 2_000

    push(joined, "exit", %{
      "request_id" => request_id,
      "status" => "completed",
      "session_id" => "acp-sess-42",
      "truncated" => false,
      "duration_ms" => 5
    })

    assert {:ok, %{"status" => "completed"}} = Task.await(caller)
  end

  test "controller refusals reach the waiting caller typed" do
    %{machine: machine, token: token} = paired_machine("run-refused")
    {:ok, socket} = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})
    {:ok, _reply, joined} = subscribe_and_join(socket, "computer:#{machine.id}", %{})

    caller =
      Task.async(fn -> Computer.request_run(machine.id, %{"argv" => ["sudo", "id"]}, 5_000) end)

    assert_push "run", %{"request_id" => request_id}

    push(joined, "refused", %{
      "request_id" => request_id,
      "reason" => "denied_command",
      "detail" => "sudo is never permitted"
    })

    assert {:refused, "denied_command", "sudo is never permitted"} = Task.await(caller)
  end

  test "a slow run times out typed and pushes a cancel to the controller" do
    %{machine: machine, token: token} = paired_machine("run-timeout")
    {:ok, socket} = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})
    {:ok, _reply, _joined} = subscribe_and_join(socket, "computer:#{machine.id}", %{})

    caller =
      Task.async(fn -> Computer.request_run(machine.id, %{"argv" => ["sleep", "60"]}, 50) end)

    assert_push "run", %{"request_id" => request_id}
    assert {:ok, result} = Task.await(caller)
    assert result["status"] == "timeout"
    assert result["truncated"] == true
    assert_push "cancel", %{"request_id" => ^request_id}
  end

  test "a caller that dies mid-request makes the channel cancel the controller delegation" do
    %{machine: machine, token: token} = paired_machine("agent-caller-death")
    {:ok, socket} = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})
    {:ok, _reply, _joined} = subscribe_and_join(socket, "computer:#{machine.id}", %{})

    # An unlinked caller so killing it does not disturb the test process. It
    # blocks in collect awaiting a terminal reply that never comes — exactly a
    # long delegation whose turn is stopped.
    caller =
      spawn(fn ->
        Computer.request_agent(
          machine.id,
          %{"agent_id" => "claude", "prompt" => "do work"},
          60_000
        )
      end)

    assert_push "agent", %{"request_id" => request_id}

    Process.exit(caller, :kill)

    # The channel monitored the caller, so its death pushes a cancel for the
    # orphaned request_id rather than leaving the ACP subprocess running.
    assert_push "cancel", %{"request_id" => ^request_id}
  end

  test "agent requests carry the agent id and prompt and return the session payload" do
    %{machine: machine, token: token} = paired_machine("agent")
    {:ok, socket} = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})
    {:ok, _reply, joined} = subscribe_and_join(socket, "computer:#{machine.id}", %{})

    caller =
      Task.async(fn ->
        Computer.request_agent(
          machine.id,
          %{
            "agent_id" => "claude",
            "prompt" => "fix the flaky test",
            "resume_session_id" => "acp-0"
          },
          5_000
        )
      end)

    assert_push "agent", %{
      "request_id" => request_id,
      "agent_id" => "claude",
      "prompt" => "fix the flaky test",
      "resume_session_id" => "acp-0"
    }

    push(joined, "chunk", %{"request_id" => request_id, "text" => "Looking at the test…"})

    push(joined, "exit", %{
      "request_id" => request_id,
      "status" => "completed",
      "stop_reason" => "end_turn",
      "session_id" => "acp-1",
      "truncated" => false,
      "duration_ms" => 300
    })

    assert {:ok, result} = Task.await(caller)
    assert result["status"] == "completed"
    assert result["session_id"] == "acp-1"
    assert result["output"] =~ "Looking at the test"
  end

  test "deprecated devin requests ride the agent event with agent_id devin" do
    %{machine: machine, token: token} = paired_machine("devin-legacy")
    {:ok, socket} = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})
    {:ok, _reply, joined} = subscribe_and_join(socket, "computer:#{machine.id}", %{})

    caller =
      Task.async(fn ->
        Computer.request_devin(
          machine.id,
          %{"prompt" => "fix the flaky test", "session_id" => "acp-7"},
          5_000
        )
      end)

    assert_push "agent", %{
      "request_id" => request_id,
      "agent_id" => "devin",
      "prompt" => "fix the flaky test",
      "resume_session_id" => "acp-7"
    }

    push(joined, "exit", %{
      "request_id" => request_id,
      "status" => "completed",
      "stop_reason" => "end_turn",
      "session_id" => "acp-7",
      "truncated" => false,
      "duration_ms" => 20
    })

    assert {:ok, result} = Task.await(caller)
    assert result["status"] == "completed"
    assert result["session_id"] == "acp-7"
  end

  test "disconnecting mid-request wakes the waiting caller typed" do
    %{machine: machine, token: token} = paired_machine("run-disconnect")
    {:ok, socket} = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})
    {:ok, _reply, joined} = subscribe_and_join(socket, "computer:#{machine.id}", %{})

    caller =
      Task.async(fn ->
        Computer.request_run(machine.id, %{"argv" => ["git", "status"]}, 5_000)
      end)

    assert_push "run", %{"request_id" => _request_id}

    Process.unlink(joined.channel_pid)
    close(joined)

    assert {:error, :machine_disconnected} = Task.await(caller)
  end

  test "revocation stops the connected channel" do
    %{owner: owner, machine: machine, token: token} = paired_machine("revoke-live")
    {:ok, socket} = connect(OpenAgentsWeb.ControllerSocket, %{"token" => token})
    {:ok, _reply, joined} = subscribe_and_join(socket, "computer:#{machine.id}", %{})

    channel_pid = joined.channel_pid
    monitor = Process.monitor(channel_pid)

    {:ok, _revoked} = Machines.revoke_machine(owner, machine.id)

    assert_receive {:DOWN, ^monitor, :process, ^channel_pid, _reason}
  end
end
