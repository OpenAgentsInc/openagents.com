defmodule OpenAgents.Tools.ComputerToolsTest do
  use OpenAgents.DataCase

  alias OpenAgents.Conversations.Message
  alias OpenAgents.Incidents
  alias OpenAgents.Machines
  alias OpenAgents.Support.FakeController
  alias OpenAgents.Tools.{ExecutionContext, Registry, Runner}
  alias OpenAgents.{Accounts, Conversations, Repo}

  @tools [
    OpenAgents.Tools.ComputerList,
    OpenAgents.Tools.ComputerProbe,
    OpenAgents.Tools.ComputerRun,
    OpenAgents.Tools.ComputerDevin,
    OpenAgents.Tools.ComputerAgent
  ]

  setup do
    assert {:ok, snapshot} = Registry.build(@tools)
    %{snapshot: snapshot}
  end

  # Wait for a started delegation's background job to reach a terminal state, so
  # its worker/task releases the shared sandbox connection before the test ends.
  defp await_delegation(outcome) do
    job_id = outcome["result"]["job_id"]

    assert eventually(fn ->
             OpenAgents.Work.get_job!(job_id).status in OpenAgents.Work.Job.terminal_statuses()
           end)
  end

  # Poll a condition for up to ~2s — the delegation job runs in a background
  # process (shared sandbox makes its writes visible here).
  defp eventually(fun, attempts \\ 40) do
    if fun.() do
      true
    else
      if attempts <= 0 do
        false
      else
        Process.sleep(50)
        eventually(fun, attempts - 1)
      end
    end
  end

  test "computer_list shows only the owner's machines with connection state", %{
    snapshot: snapshot
  } do
    scope = owner_scope("computer-lister")
    machine = paired_machine(scope.user, "listed-box")
    _foreign = paired_machine(owner_scope("computer-other").user, "foreign-box")

    assert {:ok, outcome} = Runner.run(snapshot, call("computer_list", %{}), context(scope))

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["status"] == "matches"
    assert [listed] = outcome["result"]["machines"]
    assert listed["id"] == machine.id
    assert listed["name"] == "listed-box"
    assert listed["connected"] == false
  end

  test "computer_list reports empty when nothing is paired", %{snapshot: snapshot} do
    scope = owner_scope("computer-empty")

    assert {:ok, outcome} = Runner.run(snapshot, call("computer_list", %{}), context(scope))
    assert outcome["result"]["status"] == "empty"
    assert outcome["result"]["machines"] == []
  end

  test "computer_probe falls back to the last known report when offline", %{snapshot: snapshot} do
    scope = owner_scope("computer-probe")
    machine = paired_machine(scope.user, "probed-box")

    {:ok, _updated} =
      Machines.store_probe(machine, %{
        "platform" => "linux",
        "release" => "6.8",
        "architecture" => "x64",
        "shell" => "/bin/bash",
        "acp_agents" => [
          %{
            "id" => "codex",
            "source" => "config",
            "version" => "1.4.0",
            "auth_ready" => true,
            "model" => "gpt-5.6-sol",
            "reasoning_effort" => "medium",
            "mode" => "agent-full-access"
          }
        ],
        "coding_agents" => [
          %{
            "name" => "claude",
            "present" => true,
            "path" => "/usr/bin/claude",
            "version" => "2.0"
          },
          %{"name" => "codex", "present" => false, "path" => "", "version" => ""}
        ],
        "toolchains" => [
          %{"name" => "git", "present" => true, "path" => "/usr/bin/git", "version" => "2.43"}
        ]
      })

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_probe", %{"machine_id" => machine.id}),
               context(scope)
             )

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["status"] == "ok"
    assert outcome["result"]["freshness"] == "last_known"
    assert outcome["result"]["platform"] == "linux"

    assert [
             %{
               "id" => "codex",
               "model" => "gpt-5.6-sol",
               "reasoning_effort" => "medium",
               "mode" => "agent-full-access"
             }
           ] = outcome["result"]["acp_agents"]

    assert [%{"name" => "claude"}] = outcome["result"]["coding_agents"]
    assert [%{"name" => "git"}] = outcome["result"]["toolchains"]
  end

  test "computer_probe types the offline outcome when nothing is known", %{snapshot: snapshot} do
    scope = owner_scope("computer-offline")
    machine = paired_machine(scope.user, "offline-box")

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_probe", %{"machine_id" => machine.id}),
               context(scope)
             )

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["status"] == "machine_offline"
    assert outcome["result"]["freshness"] == "unavailable"
    assert outcome["result"]["acp_agents"] == []
    assert outcome["result"]["coding_agents"] == []
  end

  test "computer_probe refuses machines the owner does not hold", %{snapshot: snapshot} do
    scope = owner_scope("computer-scoped")
    foreign = paired_machine(owner_scope("computer-foreign").user, "not-yours")

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_probe", %{"machine_id" => foreign.id}),
               context(scope)
             )

    assert outcome["status"] == "failed"
    assert outcome["error"]["code"] == "machine_not_found"
  end

  test "computer_run streams a command's output and returns its exit code", %{
    snapshot: snapshot
  } do
    scope = owner_scope("computer-run")
    machine = paired_machine(scope.user, "run-box", "curated")

    connect(machine.id, fn {:run, request_id, payload, caller} ->
      assert payload["argv"] == ["git", "status"]
      assert payload["timeout_ms"] == 5_000
      FakeController.chunk(caller, request_id, "On branch main\n")
      FakeController.chunk(caller, request_id, "nothing to commit\n")

      FakeController.exit(caller, request_id, %{
        "status" => "completed",
        "exit_code" => 0,
        "truncated" => false,
        "duration_ms" => 42
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_run", %{
                 "machine_id" => machine.id,
                 "argv" => ["git", "status"],
                 "timeout_ms" => 5_000
               }),
               context(scope)
             )

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["status"] == "completed"
    assert outcome["result"]["exit_code"] == 0
    assert outcome["result"]["output"] == "On branch main\nnothing to commit\n"
    assert outcome["result"]["duration_ms"] == 42
  end

  test "computer_run surfaces a local policy refusal without executing", %{snapshot: snapshot} do
    scope = owner_scope("computer-refused")
    machine = paired_machine(scope.user, "refusing-box", "curated")

    connect(machine.id, fn {:run, request_id, _payload, caller} ->
      FakeController.refused(caller, request_id, "denied_command", "sudo is never permitted")
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_run", %{"machine_id" => machine.id, "argv" => ["sudo", "rm"]}),
               context(scope)
             )

    assert outcome["result"]["status"] == "refused"
    assert outcome["result"]["detail"] =~ "denied_command"
    assert outcome["result"]["output"] == ""
  end

  test "computer_run types the offline machine instead of guessing", %{snapshot: snapshot} do
    scope = owner_scope("computer-run-offline")
    machine = paired_machine(scope.user, "absent-box", "curated")

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_run", %{"machine_id" => machine.id, "argv" => ["git", "status"]}),
               context(scope)
             )

    assert outcome["result"]["status"] == "machine_offline"
  end

  test "computer_run rejects a shell string masquerading as a command", %{snapshot: snapshot} do
    scope = owner_scope("computer-run-invalid")
    machine = paired_machine(scope.user, "invalid-box", "curated")

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_run", %{"machine_id" => machine.id, "argv" => "rm -rf / | sh"}),
               context(scope)
             )

    assert outcome["status"] == "failed"
  end

  test "computer_run refuses machines the owner does not hold", %{snapshot: snapshot} do
    scope = owner_scope("computer-run-scoped")
    _own = paired_machine(scope.user, "own-box", "curated")
    foreign = paired_machine(owner_scope("computer-run-foreign").user, "not-yours", "curated")

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_run", %{"machine_id" => foreign.id, "argv" => ["git", "status"]}),
               context(scope)
             )

    assert outcome["status"] == "failed"
    assert outcome["error"]["code"] == "machine_not_found"
  end

  test "computer_run is refused outright when no machine pairing backs it", %{snapshot: snapshot} do
    scope = owner_scope("computer-run-unapproved")

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_run", %{"machine_id" => Ecto.UUID.generate(), "argv" => ["ls"]}),
               context(scope)
             )

    assert outcome["status"] == "refused"
    assert outcome["error"]["code"] == "module_approval_required"
  end

  test "computer_devin returns streamed agent output with its session id", %{snapshot: snapshot} do
    scope = owner_scope("computer-devin")
    machine = paired_machine(scope.user, "devin-box", "curated")

    connect(machine.id, fn {:agent, request_id, payload, caller} ->
      assert payload["agent_id"] == "devin"
      assert payload["prompt"] == "add a test for the parser"
      FakeController.chunk(caller, request_id, "reading the parser… ")

      FakeController.exit(caller, request_id, %{
        "status" => "completed",
        "stop_reason" => "end_turn",
        "session_id" => "acp-session-1",
        "truncated" => false,
        "duration_ms" => 900,
        "detail" => ""
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_devin", %{
                 "machine_id" => machine.id,
                 "prompt" => "add a test for the parser"
               }),
               context(scope)
             )

    assert outcome["result"]["status"] == "completed"
    assert outcome["result"]["stop_reason"] == "end_turn"
    assert outcome["result"]["session_id"] == "acp-session-1"
    assert outcome["result"]["output"] =~ "reading the parser"
  end

  test "computer_devin reports an unavailable agent plainly", %{snapshot: snapshot} do
    scope = owner_scope("computer-devin-missing")
    machine = paired_machine(scope.user, "no-devin-box", "curated")

    connect(machine.id, fn {:agent, request_id, payload, caller} ->
      assert payload["agent_id"] == "devin"

      FakeController.exit(caller, request_id, %{
        "status" => "unavailable",
        "detail" => "devin is not installed on this machine",
        "session_id" => "",
        "truncated" => false,
        "duration_ms" => 0
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_devin", %{"machine_id" => machine.id, "prompt" => "do a thing"}),
               context(scope)
             )

    assert outcome["result"]["status"] == "unavailable"
    assert outcome["result"]["detail"] =~ "not installed"
  end

  test "computer_devin refuses an empty prompt", %{snapshot: snapshot} do
    scope = owner_scope("computer-devin-empty")
    machine = paired_machine(scope.user, "empty-prompt-box", "curated")

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_devin", %{"machine_id" => machine.id, "prompt" => "   "}),
               context(scope)
             )

    assert outcome["status"] == "failed"
  end

  test "computer_agent delegates to a probed agent and records the session", %{
    snapshot: snapshot
  } do
    scope = owner_scope("computer-agent")
    machine = probed_agent_machine(scope.user, "agent-box", ["claude", "codex"])

    connect(machine.id, fn {:agent, request_id, payload, caller} ->
      assert payload["agent_id"] == "claude"
      assert payload["prompt"] == "summarize the failing test"
      assert is_integer(payload["timeout_ms"])
      assert payload["timeout_ms"] > 480_000
      FakeController.chunk(caller, request_id, "reading the test… ")

      FakeController.exit(caller, request_id, %{
        "status" => "completed",
        "stop_reason" => "end_turn",
        "session_id" => "acp-session-9",
        "agent_id" => "claude",
        "truncated" => false,
        "duration_ms" => 1_200,
        "detail" => ""
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => machine.id,
                 "agent_id" => "claude",
                 "prompt" => "summarize the failing test"
               }),
               context(scope)
             )

    # The tool returns immediately: it succeeded at STARTING a durable
    # background delegation, so several can run at once and the turn is not held.
    assert outcome["status"] == "succeeded"
    assert outcome["result"]["status"] == "started"
    assert outcome["result"]["agent_id"] == "claude"
    assert outcome["target_receipt_refs"] == ["machine:#{machine.id}"]
    job_id = outcome["result"]["job_id"]
    assert job_id != ""

    # The background delegation job runs to completion and reports its outcome.
    assert eventually(fn -> OpenAgents.Work.get_job!(job_id).status == "completed" end)
    job = OpenAgents.Work.get_job!(job_id)
    assert job.kind == "delegation"
    assert job.report =~ "Delegation to claude"
  end

  test "computer_agent is refused without the machine-pairing approval receipt", %{
    snapshot: snapshot
  } do
    # A context that carries computer.control authority but no approval receipts
    # — the shape a durable job would have had before it was taught to supply
    # Machines.approval_receipts. The delegation must refuse, not run unapproved.
    scope = owner_scope("computer-agent-unapproved")
    machine = probed_agent_machine(scope.user, "unapproved-box", ["claude"])

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => machine.id,
                 "agent_id" => "claude",
                 "prompt" => "say hi"
               }),
               context(scope, [])
             )

    assert outcome["status"] == "refused"
    assert outcome["error"]["code"] == "module_approval_required"
  end

  test "a job-shaped context with pairing receipts authorizes a delegation", %{snapshot: snapshot} do
    # The durable-job path: same owner, same conversation scope_ref, receipts
    # derived exactly as OpenAgents.Work.JobServer now derives them. The delegation
    # runs to completion so a long coding task can outlast a single turn.
    scope = owner_scope("computer-agent-job")
    machine = probed_agent_machine(scope.user, "job-box", ["claude"])

    connect(machine.id, fn {:agent, request_id, _payload, caller} ->
      FakeController.exit(caller, request_id, %{
        "status" => "completed",
        "stop_reason" => "end_turn",
        "session_id" => "acp-job-1",
        "agent_id" => "claude",
        "truncated" => false,
        "duration_ms" => 900,
        "detail" => ""
      })
    end)

    receipts = Machines.approval_receipts(scope.user.id, scope_ref(scope))
    assert receipts != []

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => machine.id,
                 "agent_id" => "claude",
                 "prompt" => "say hi"
               }),
               context(scope, receipts)
             )

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["status"] == "started"
    assert outcome["result"]["job_id"] != ""
    await_delegation(outcome)
  end

  test "computer_agent resolves the machine when exactly one is active", %{snapshot: snapshot} do
    scope = owner_scope("computer-agent-default")
    machine = probed_agent_machine(scope.user, "only-box", ["claude"])

    connect(machine.id, fn {:agent, request_id, _payload, caller} ->
      FakeController.exit(caller, request_id, %{
        "status" => "completed",
        "stop_reason" => "end_turn",
        "session_id" => "acp-session-10",
        "truncated" => false,
        "duration_ms" => 5,
        "detail" => ""
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{"agent_id" => "claude", "prompt" => "say hi"}),
               context(scope)
             )

    assert outcome["result"]["status"] == "started"
    assert outcome["result"]["machine_id"] == machine.id
    await_delegation(outcome)
  end

  test "computer_agent types an ambiguous omitted machine", %{snapshot: snapshot} do
    scope = owner_scope("computer-agent-ambiguous")
    _first = probed_agent_machine(scope.user, "first-box", ["claude"])
    _second = probed_agent_machine(scope.user, "second-box", ["claude"])

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{"agent_id" => "claude", "prompt" => "say hi"}),
               context(scope)
             )

    assert outcome["status"] == "failed"
    assert outcome["error"]["code"] == "ambiguous_machine"
  end

  test "computer_agent refuses an agent absent from the probe inventory naming the ids", %{
    snapshot: snapshot
  } do
    scope = owner_scope("computer-agent-unknown")
    machine = probed_agent_machine(scope.user, "known-box", ["claude", "codex"])

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => machine.id,
                 "agent_id" => "gemini",
                 "prompt" => "do a thing"
               }),
               context(scope)
             )

    assert outcome["status"] == "refused"
    assert outcome["result"]["status"] == "refused"
    assert outcome["result"]["detail"] =~ "agent_not_available"
    assert outcome["result"]["detail"] =~ "gemini"
    assert outcome["result"]["detail"] =~ "claude, codex"
  end

  test "computer_agent refuses honestly when no agents were ever probed", %{snapshot: snapshot} do
    scope = owner_scope("computer-agent-unprobed")
    machine = paired_machine(scope.user, "unprobed-box", "curated")

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => machine.id,
                 "agent_id" => "claude",
                 "prompt" => "do a thing"
               }),
               context(scope)
             )

    assert outcome["result"]["status"] == "refused"
    assert outcome["result"]["detail"] =~ "computer_probe"
  end

  test "computer_agent maps an auth-required agent to a typed unavailable step", %{
    snapshot: snapshot
  } do
    scope = owner_scope("computer-agent-auth")
    machine = probed_agent_machine(scope.user, "auth-box", ["claude"])

    connect(machine.id, fn {:agent, request_id, _payload, caller} ->
      FakeController.exit(caller, request_id, %{
        "status" => "unavailable",
        "detail" => "claude needs a login: run `claude /login` (authMethods: oauth)",
        "session_id" => "",
        "stop_reason" => "",
        "truncated" => false,
        "duration_ms" => 0
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => machine.id,
                 "agent_id" => "claude",
                 "prompt" => "do a thing"
               }),
               context(scope)
             )

    # The outcome now lives on the background delegation job: starting succeeds,
    # the job then fails and its report carries the honest reason.
    assert outcome["result"]["status"] == "started"
    await_delegation(outcome)
    job = OpenAgents.Work.get_job!(outcome["result"]["job_id"])
    assert job.status == "failed"
    assert job.report =~ "authMethods"
  end

  test "computer_agent maps a cancelled delegation to a cancelled step", %{snapshot: snapshot} do
    scope = owner_scope("computer-agent-cancelled")
    machine = probed_agent_machine(scope.user, "cancel-box", ["claude"])

    connect(machine.id, fn {:agent, request_id, _payload, caller} ->
      FakeController.exit(caller, request_id, %{
        "status" => "cancelled",
        "stop_reason" => "cancelled",
        "session_id" => "acp-session-11",
        "truncated" => false,
        "duration_ms" => 40,
        "detail" => "the user cancelled the delegation"
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => machine.id,
                 "agent_id" => "claude",
                 "prompt" => "do a thing"
               }),
               context(scope)
             )

    assert outcome["result"]["status"] == "started"
    await_delegation(outcome)
    job = OpenAgents.Work.get_job!(outcome["result"]["job_id"])
    assert job.status == "failed"
    assert job.report =~ "cancelled"

    [incident] = Incidents.list_recent(scope.user.id, conversation_id: scope.conversation.id)
    assert incident.code == "delegation_cancelled"
    assert incident.severity == "expected"
    assert incident.correlation_ref == job.id
  end

  test "computer_agent reports a timed-out delegation as a failed step with its partial output",
       %{snapshot: snapshot} do
    scope = owner_scope("computer-agent-timeout")
    machine = probed_agent_machine(scope.user, "slow-box", ["claude"])

    connect(machine.id, fn {:agent, request_id, _payload, caller} ->
      FakeController.chunk(caller, request_id, "partial investigation notes before the ceiling")

      FakeController.exit(caller, request_id, %{
        "status" => "timeout",
        "stop_reason" => "",
        "session_id" => "acp-session-12",
        "truncated" => true,
        "duration_ms" => 300_011,
        "detail" => ""
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => machine.id,
                 "agent_id" => "claude",
                 "prompt" => "do a slow thing"
               }),
               context(scope)
             )

    # The honest outcome now lands on the background job: a timed-out delegation
    # is a failed job whose report keeps its partial evidence.
    assert outcome["result"]["status"] == "started"
    await_delegation(outcome)
    job = OpenAgents.Work.get_job!(outcome["result"]["job_id"])
    assert job.status == "failed"
    assert job.report =~ "timed out"
    assert job.report =~ "Session: acp-session-12"
    assert job.report =~ "partial investigation notes"

    [incident] = Incidents.list_recent(scope.user.id, conversation_id: scope.conversation.id)
    assert incident.code == "delegation_timeout"
    assert incident.severity == "degraded"
    assert incident.origin == "delegation_server"
    assert incident.correlation_ref == job.id
    assert incident.fixer_job_id == nil
  end

  test "computer_agent decodes framed ACP output into a readable job report", %{
    snapshot: snapshot
  } do
    scope = owner_scope("computer-agent-acp-frames")
    machine = probed_agent_machine(scope.user, "framed-box", ["claude"])
    rs = <<30>>
    us = <<31>>

    framed =
      "I'll inspect the repo.\n" <>
        rs <>
        Enum.join(
          [
            "T",
            "toolu_01RG3K9PWRWs1KQnqBMEzWpr",
            "2",
            "edit",
            Base.encode64("chat_live.ex"),
            Base.encode64("User refused permission to run tool")
          ],
          us
        ) <>
        "\n"

    connect(machine.id, fn {:agent, request_id, _payload, caller} ->
      FakeController.chunk(caller, request_id, framed)

      FakeController.exit(caller, request_id, %{
        "status" => "timeout",
        "stop_reason" => "",
        "session_id" => "acp-framed-1",
        "truncated" => true,
        "duration_ms" => 480_000,
        "detail" => ""
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => machine.id,
                 "agent_id" => "claude",
                 "prompt" => "inspect"
               }),
               context(scope)
             )

    await_delegation(outcome)
    job = OpenAgents.Work.get_job!(outcome["result"]["job_id"])
    assert job.status == "failed"
    assert job.report =~ "I'll inspect the repo."
    assert job.report =~ "Write tools were refused by the machine policy"
    assert job.report =~ "Edit: chat_live.ex (failed)"
    refute job.report =~ "toolu_"
    refute job.report =~ "VGVybWluYWw"
    refute job.report =~ rs
  end

  test "computer_agent types the offline machine instead of guessing", %{snapshot: snapshot} do
    scope = owner_scope("computer-agent-offline")
    machine = probed_agent_machine(scope.user, "away-box", ["claude"])

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => machine.id,
                 "agent_id" => "claude",
                 "prompt" => "do a thing"
               }),
               context(scope)
             )

    # No controller is connected, so no durable job is misleadingly queued.
    assert outcome["status"] == "failed"
    assert outcome["result"]["status"] == "machine_offline"
    assert outcome["result"]["job_id"] == ""
  end

  test "computer_agent round-trips resume_session_id into the durable result", %{
    snapshot: snapshot
  } do
    scope = owner_scope("computer-agent-resume")
    machine = probed_agent_machine(scope.user, "resume-box", ["claude"])

    connect(machine.id, fn {:agent, request_id, payload, caller} ->
      assert payload["resume_session_id"] == "acp-session-42"

      FakeController.exit(caller, request_id, %{
        "status" => "completed",
        "stop_reason" => "end_turn",
        "session_id" => "acp-session-42",
        "truncated" => false,
        "duration_ms" => 80,
        "detail" => ""
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => machine.id,
                 "agent_id" => "claude",
                 "prompt" => "keep going",
                 "resume_session_id" => "acp-session-42"
               }),
               context(scope)
             )

    # resume_session_id is threaded to the delegation (the controller asserts it
    # in the connect script above); the job then completes.
    assert outcome["result"]["status"] == "started"
    assert outcome["result"]["resume_session_id"] == "acp-session-42"
    await_delegation(outcome)
    assert OpenAgents.Work.get_job!(outcome["result"]["job_id"]).status == "completed"
  end

  test "computer_agent resumes the last same-cwd timed-out session", %{snapshot: snapshot} do
    scope = owner_scope("computer-agent-autoresume")
    machine = probed_agent_machine(scope.user, "autoresume-box", ["claude"])

    connect(machine.id, fn {:agent, request_id, payload, caller} ->
      if payload["resume_session_id"] == "acp-prior-9" do
        FakeController.exit(caller, request_id, %{
          "status" => "completed",
          "session_id" => "acp-prior-9",
          "truncated" => false,
          "duration_ms" => 5,
          "detail" => ""
        })
      else
        FakeController.exit(caller, request_id, %{
          "status" => "timeout",
          "session_id" => "acp-prior-9",
          "truncated" => true,
          "duration_ms" => 10,
          "detail" => ""
        })
      end
    end)

    assert {:ok, first} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => machine.id,
                 "agent_id" => "claude",
                 "prompt" => "first pass",
                 "cwd" => "/Users/test/work/openagents.com"
               }),
               context(scope)
             )

    await_delegation(first)

    assert {:ok, second} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => machine.id,
                 "agent_id" => "claude",
                 "prompt" => "retry the same work",
                 "cwd" => "/Users/test/work/openagents.com"
               }),
               context(scope)
             )

    assert second["result"]["resume_session_id"] == "acp-prior-9"
    await_delegation(second)
  end

  test "computer_agent refuses a pairing-root cwd and asks for a project path", %{
    snapshot: snapshot
  } do
    scope = owner_scope("computer-agent-cwd-root")
    _machine = probed_agent_machine(scope.user, "root-box", ["claude"])

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call_raw("computer_agent", %{
                 "agent_id" => "claude",
                 "prompt" => "implement the input-bar refactor",
                 "cwd" => "/Users/christopherdavid/work"
               }),
               context(scope)
             )

    assert outcome["status"] == "refused"
    assert outcome["result"]["detail"] =~ "cwd_required"
  end

  test "computer_agent infers cwd from a path named in the prompt", %{snapshot: snapshot} do
    scope = owner_scope("computer-agent-cwd-infer")
    machine = probed_agent_machine(scope.user, "infer-box", ["claude"])

    connect(machine.id, fn {:agent, request_id, payload, caller} ->
      assert payload["cwd"] == "/Users/test/work/openagents.com"

      FakeController.exit(caller, request_id, %{
        "status" => "completed",
        "stop_reason" => "end_turn",
        "session_id" => "acp-cwd-1",
        "truncated" => false,
        "duration_ms" => 10,
        "detail" => ""
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call_raw("computer_agent", %{
                 "agent_id" => "claude",
                 "prompt" =>
                   "Work only in /Users/test/work/openagents.com. Do not touch openagents."
               }),
               context(scope)
             )

    assert outcome["result"]["status"] == "started"
    assert outcome["result"]["cwd"] == "/Users/test/work/openagents.com"
    await_delegation(outcome)
  end

  test "computer_agent is refused outright when no machine pairing backs it", %{
    snapshot: snapshot
  } do
    scope = owner_scope("computer-agent-unapproved")

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("computer_agent", %{
                 "machine_id" => Ecto.UUID.generate(),
                 "agent_id" => "claude",
                 "prompt" => "do a thing"
               }),
               context(scope)
             )

    assert outcome["status"] == "refused"
    assert outcome["error"]["code"] == "module_approval_required"
  end

  defp probed_agent_machine(user, name, agent_ids) do
    machine = paired_machine(user, name, "curated")

    {:ok, probed} =
      Machines.store_probe(machine, %{
        "platform" => "linux",
        "acp_agents" =>
          Enum.map(
            agent_ids,
            &%{"id" => &1, "source" => "builtin", "version" => "1.0", "auth_ready" => true}
          )
      })

    probed
  end

  defp connect(machine_id, script) do
    start_supervised!({FakeController, machine_id: machine_id, script: script})
  end

  defp paired_machine(user, name, tier \\ "probe") do
    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => name,
        "tier" => tier,
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => ["/Users/test/work", "/Users/christopherdavid/work"]
      })

    {:ok, machine} = Machines.approve_pairing(user, code)
    machine
  end

  defp call("computer_agent", arguments) do
    call_raw("computer_agent", Map.put_new(arguments, "cwd", "/Users/test/work/openagents.com"))
  end

  defp call(name, arguments), do: call_raw(name, arguments)

  defp call_raw(name, arguments) do
    %{
      call_id: "call-#{System.unique_integer([:positive])}",
      name: name,
      version: 1,
      raw_arguments: Jason.encode!(arguments)
    }
  end

  defp owner_scope(login) do
    assert {:ok, user} =
             Accounts.upsert_github_user(%{
               github_id: System.unique_integer([:positive]),
               github_login: login,
               github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
             })

    assert {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Repo.get!(OpenAgents.Conversations.Visitor, conversation.visitor_id)
    %{user: user, owner: owner, conversation: conversation}
  end

  defp context(scope),
    do: context(scope, Machines.approval_receipts(scope.user.id, scope_ref(scope)))

  defp context(scope, approval_receipts) do
    message =
      Repo.insert!(%Message{
        conversation_id: scope.conversation.id,
        role: "user",
        status: "complete",
        content: "What's on my computer?"
      })

    %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: scope_ref(scope),
      authorities: MapSet.new(["computer.control"]),
      approval_receipts: approval_receipts,
      conversation_id: scope.conversation.id,
      current_user_message_id: message.id,
      owner_visitor_id: scope.owner.id
    }
  end

  defp scope_ref(scope), do: "conversation:#{scope.conversation.id}"
end
