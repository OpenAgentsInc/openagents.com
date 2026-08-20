defmodule OpenAgents.WorkJobTest do
  use OpenAgents.DataCase
  alias OpenAgents.{Accounts, Conversations, Machines, Work, WorkRecovery}
  alias OpenAgents.Conversations.Message
  alias OpenAgents.Work.{Job, JobServer}

  setup do
    Application.put_env(:openagents, :test_tool_observer, self())
    on_exit(fn -> Application.delete_env(:openagents, :test_tool_observer) end)
    :ok
  end

  test "a multi-step job completes with durable steps and a report message" do
    {conversation, job} = create_job("work-happy-path", "[deep-work-job]")

    run_job_to_exit(job)

    finished = Work.get_job!(job.id)
    assert finished.status == "completed"

    assert finished.report ==
             "Deep work report: both lookarounds succeeded; found dw-alpha and dw-beta."

    assert finished.error_code == nil
    assert finished.model_id == Application.fetch_env!(:openagents, :openai_model)
    assert finished.instruction_digest =~ ~r/^[0-9a-f]{64}$/
    assert finished.tool_catalog_digest =~ ~r/^[0-9a-f]{64}$/
    assert finished.tool_call_count == 2
    assert finished.usage["input_tokens"] > 0

    assert_receive {:test_tool_executed, _pid, "dw-alpha", scope_ref}
    assert scope_ref == "conversation:#{conversation.id}"
    assert_receive {:test_tool_executed, _pid, "dw-beta", _scope_ref}

    assert [first, second] = Work.list_job_steps(finished)
    assert first.tool_name == "recall_messages"
    assert first.status == "succeeded"
    assert first.provider_call_id == "call-deep-work-1"
    assert first.result == %{"matches" => ["Found dw-alpha in this conversation."]}
    assert second.status == "succeeded"
    assert second.provider_call_id == "call-deep-work-2"

    report_message = Repo.get!(Message, finished.report_message_id)
    assert report_message.role == "assistant"
    assert report_message.status == "complete"
    assert report_message.conversation_id == conversation.id
    assert report_message.work_job_id == finished.id
    assert report_message.content == finished.report

    # The durable report is ordinary conversation evidence for later turns.
    assert Enum.any?(
             Conversations.provider_messages(conversation.id),
             &(&1.content == finished.report and &1.role == "assistant")
           )
  end

  test "a tool-free goal completes with the model text as the report" do
    {_conversation, job} = create_job("work-tool-free", "just summarize the plan")

    run_job_to_exit(job)

    finished = Work.get_job!(job.id)
    assert finished.status == "completed"
    assert finished.report == "I hear you. You said: just summarize the plan"
    assert Work.list_job_steps(finished) == []
    assert Repo.get!(Message, finished.report_message_id).content == finished.report
  end

  test "the tool-call ceiling forces a tool-free partial report and an explicit terminal status" do
    {_conversation, job} = create_job("work-limit-path", "[deep-work-limit]")

    run_job_to_exit(job, 15_000)

    finished = Work.get_job!(job.id)
    assert finished.status == "budget_exhausted"
    assert finished.error_code == "tool_call_limit_reached"

    assert finished.report ==
             "Deep work partial report: the host limit ended the search (failed)."

    steps = Work.list_job_steps(finished)
    assert length(steps) == 33

    {completed, [limited]} = Enum.split(steps, 32)
    assert Enum.all?(completed, &(&1.status == "succeeded"))
    assert limited.status == "failed"
    assert limited.error["code"] == "tool_call_limit_reached"

    report_message = Repo.get!(Message, finished.report_message_id)
    assert report_message.content == finished.report
  end

  test "startup recovery resumes an orphaned running job instead of burying it" do
    {_conversation, job} = create_job("work-recovery", "[deep-work-block]")

    pid = start_supervised!({JobServer, job.id})
    monitor = Process.monitor(pid)

    assert_receive {:test_tool_executed, tool_pid, "block", _scope_ref}, 2_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    tool_ref = Process.monitor(tool_pid)
    send(tool_pid, :release_test_tool)

    before_recovery = Work.get_job!(job.id)
    assert before_recovery.status == "running"

    # Recovery restarts the worker: it re-claims through the generation fence
    # (adopt) and continues the work — the job is NOT finalized interrupted.
    run_work_recovery()

    # The restarted worker adopted the row through the fence (generation bumped)
    # and drove the job to a REAL terminal state — never the buried
    # `interrupted`/`runtime_restarted`. (Under the test stub the resumed
    # provider run ends `failed` quickly — the stub binds to the test process —
    # which is still an honest terminal outcome produced by actual resumed
    # work, not a burial.)
    final = wait_for_terminal(job.id)
    assert_receive {:DOWN, ^tool_ref, :process, ^tool_pid, _reason}
    await_worker_exit(job.id)
    assert final.generation > before_recovery.generation
    refute final.status == "interrupted"
    assert final.error_code != "runtime_restarted"
    # (The restart's durable runtime_restarted incident is asserted in
    # "boot recovery records a degraded incident..." below, which owns a real
    # user account — this job's anonymous visitor has no user incident feed.)
  end

  # A job whose singleton is already alive must not be disturbed (fleet: a
  # rebooting node must never bury or duplicate a job running on a survivor).
  test "startup recovery leaves an already-running singleton untouched" do
    {_conversation, job} = create_job("work-recovery-live", "[deep-work-block]")

    _pid = start_supervised!({JobServer, job.id})
    assert_receive {:test_tool_executed, tool_pid, "block", _scope_ref}, 2_000

    running = Work.get_job!(job.id)
    assert running.status == "running"

    assert :ok = Work.recover_interrupted_jobs()

    undisturbed = Work.get_job!(job.id)
    assert undisturbed.status == "running"
    # No second adoption: the generation is unchanged.
    assert undisturbed.generation == running.generation

    tool_ref = Process.monitor(tool_pid)
    send(tool_pid, :release_test_tool)
    final = wait_for_terminal(job.id)
    assert_receive {:DOWN, ^tool_ref, :process, ^tool_pid, _reason}
    await_worker_exit(job.id)
    refute final.status == "interrupted"
  end

  defp wait_for_terminal(job_id, timeout_ms \\ 10_000) do
    job = Work.get_job!(job_id)

    if job.status in Job.terminal_statuses() do
      job
    else
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      await_terminal(job_id, job.status, deadline)
    end
  end

  defp await_terminal(job_id, last_status, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:work_job_updated, %Job{id: ^job_id, status: status} = job}
      when status in ["completed", "failed", "interrupted", "budget_exhausted", "cancelled"] ->
        job

      {:work_job_updated, %Job{id: ^job_id, status: status}} ->
        await_terminal(job_id, status, deadline)
    after
      remaining -> flunk("job never reached a terminal status (stuck #{last_status})")
    end
  end

  test "terminal jobs are immutable and active jobs cannot skip transitions" do
    {_conversation, job} = create_job("work-append-only", "just a report")

    run_job_to_exit(job)
    finished = Work.get_job!(job.id)
    assert finished.status == "completed"

    assert_raise Postgrex.Error, ~r/terminal work job is immutable/, fn ->
      finished
      |> Ecto.Changeset.change(report: "rewritten history")
      |> Repo.update()
    end

    {_conversation, queued} = create_job("work-bad-transition", "never started")

    assert_raise Postgrex.Error, ~r/invalid queued work job transition/, fn ->
      queued
      |> Ecto.Changeset.change(status: "completed", completed_at: DateTime.utc_now(), report: "x")
      |> Repo.update()
    end
  end

  test "an interrupted delegation job reports honestly, not with deep-work text" do
    {_conversation, job} =
      create_delegation_job(
        "deleg-report-browser",
        "Delegate to claude on devin-test: refactor the input bar"
      )

    {:ok, finished} = Work.finish_job(job.id, "interrupted", error_code: "runtime_restarted")

    assert finished.status == "interrupted"

    assert finished.report =~
             "Delegation to claude on devin-test-deleg-report-browser was interrupted by a server restart"

    refute finished.report =~ "Deep work job"
    refute finished.report =~ "no tool calls had completed"
  end

  test "cancel_job finishes a queued job as cancelled with an honest report" do
    {_conversation, job} =
      create_delegation_job(
        "deleg-cancel-browser",
        "Delegate to claude on devin-test: refactor the input bar"
      )

    assert {:ok, finished} = Work.cancel_job(job.id)
    assert finished.status == "cancelled"
    assert finished.error_code == "cancelled"
    assert finished.report =~ "was cancelled"
  end

  test "checkpoint_delegation_session persists the session id only for the live generation" do
    {_conversation, job} =
      create_delegation_job(
        "deleg-ckpt-browser",
        "Delegate to claude on devin-test: do work"
      )

    {:ok, running} = Work.claim_for_run(job.id)

    # The live owner's checkpoint lands in the durable row...
    assert {:ok, :ok} =
             Work.checkpoint_delegation_session(job.id, running.generation, "sess-live")

    assert Work.get_job!(job.id).delegation["resume_session_id"] == "sess-live"

    # ...a superseded generation's write is fenced out...
    assert {:ok, :fenced} =
             Work.checkpoint_delegation_session(job.id, running.generation - 1, "sess-zombie")

    assert Work.get_job!(job.id).delegation["resume_session_id"] == "sess-live"

    # ...and a terminal job accepts no checkpoint at all.
    {:ok, _finished} = Work.finish_job(job.id, "cancelled", error_code: "cancelled")

    assert {:ok, :fenced} =
             Work.checkpoint_delegation_session(job.id, running.generation, "sess-late")
  end

  test "delegation execution identity is immutable except for its fenced session checkpoint" do
    {_conversation, job} =
      create_delegation_job(
        "deleg-immutable-execution",
        "Delegate to claude on devin-test: do work"
      )

    assert_raise Postgrex.Error, ~r/work job identity is immutable/, fn ->
      job
      |> Ecto.Changeset.change(
        delegation: Map.put(job.delegation, "prompt", "replace the admitted prompt")
      )
      |> Repo.update!()
    end

    assert_raise Ecto.ConstraintError, ~r/work_jobs_delegation_identity/, fn ->
      Repo.insert!(%Job{
        conversation_id: job.conversation_id,
        owner_visitor_id: job.owner_visitor_id,
        machine_id: job.machine_id,
        surface: "text",
        goal: "A mismatched budget must fail",
        kind: "delegation",
        delegation: Map.put(job.delegation, "timeout_ms", 1),
        authority_snapshot: job.authority_snapshot,
        budget_snapshot: job.budget_snapshot
      })
    end

    assert_raise Postgrex.Error, ~r/work job machine authority snapshot mismatch/, fn ->
      Repo.insert!(%Job{
        conversation_id: job.conversation_id,
        owner_visitor_id: job.owner_visitor_id,
        machine_id: job.machine_id,
        surface: "text",
        goal: "A false machine authority snapshot must fail",
        kind: "delegation",
        delegation: job.delegation,
        authority_snapshot: Map.put(job.authority_snapshot, "roots", ["/tmp/foreign-root"]),
        budget_snapshot: job.budget_snapshot
      })
    end
  end

  test "boot recovery records a degraded incident for each interrupted job" do
    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: "deleg-recover",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)
    machine = machine_for(user, "deleg-recover")
    :ok = Work.subscribe(conversation.id)

    {:ok, job} =
      Work.create_job(
        delegation_attributes(
          conversation,
          owner,
          machine,
          "Delegate to claude on devin-test: do work"
        )
      )

    run_work_recovery()

    # Resume-first recovery still restarts this delegation's worker; with no
    # machine connected it finishes honestly (machine_offline) — let it settle
    # so the async worker never outlives the test's DB sandbox.
    final = wait_for_terminal(job.id)
    await_worker_exit(job.id)
    refute final.status == "interrupted"

    incidents = OpenAgents.Incidents.list_recent(owner.user_id)
    incident = Enum.find(incidents, &(&1.code == "runtime_restarted"))
    assert incident
    # A restart is degraded, not anomalous — recorded, never auto-escalated.
    assert incident.severity == "degraded"
    assert incident.surface == "delegation"
  end

  test "the database rejects a delegated machine owned by another account" do
    {_conversation, admitted} =
      create_delegation_job(
        "deleg-owner-boundary",
        "Delegate to claude on devin-test: preserve the owner boundary"
      )

    {:ok, outsider} =
      Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: "deleg-owner-outsider",
        github_avatar_url: "https://avatars.githubusercontent.com/u/2?v=4"
      })

    foreign_machine = machine_for(outsider, "deleg-owner-outsider")

    assert_raise Postgrex.Error, ~r/work job machine owner mismatch/, fn ->
      Repo.insert!(%Job{
        conversation_id: admitted.conversation_id,
        owner_visitor_id: admitted.owner_visitor_id,
        machine_id: foreign_machine.id,
        surface: "text",
        goal: "Cross-account delegation must fail",
        kind: "delegation",
        delegation: Map.put(admitted.delegation, "machine_id", foreign_machine.id),
        authority_snapshot: admitted.authority_snapshot,
        budget_snapshot: admitted.budget_snapshot
      })
    end
  end

  defp create_job(browser_key, goal) do
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    owner = Conversations.get_conversation_owner!(conversation)
    :ok = Work.subscribe(conversation.id)

    assert {:ok, job} =
             Work.create_job(%{
               conversation_id: conversation.id,
               owner_visitor_id: owner.id,
               surface: "text",
               goal: goal
             })

    {conversation, job}
  end

  defp create_delegation_job(key, goal) do
    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: key,
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)
    :ok = Work.subscribe(conversation.id)
    machine = machine_for(user, key)
    {:ok, job} = Work.create_job(delegation_attributes(conversation, owner, machine, goal))
    {conversation, job}
  end

  defp machine_for(user, key) do
    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => "devin-test-#{key}",
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => ["/tmp/openagents-work"]
      })

    {:ok, machine} = Machines.approve_pairing(user, code)
    machine
  end

  defp delegation_attributes(conversation, owner, machine, goal) do
    %{
      conversation_id: conversation.id,
      owner_visitor_id: owner.id,
      machine_id: machine.id,
      surface: "text",
      goal: goal,
      kind: "delegation",
      delegation: %{
        "agent_id" => "claude",
        "machine_id" => machine.id,
        "machine_name" => machine.name,
        "prompt" => "do work",
        "cwd" => "/tmp/openagents-work",
        "timeout_ms" => 3_600_000
      },
      authority_snapshot: %{
        "machine_tier" => machine.tier,
        "roots" => machine.roots,
        "cwd" => "/tmp/openagents-work",
        "agent_id" => "claude",
        "machine_name" => machine.name
      },
      budget_snapshot: %{
        "wall_clock_ms" => 3_600_000,
        "maximum_prompt_bytes" => 8_000,
        "maximum_report_bytes" => 8_000
      }
    }
  end

  defp run_job_to_exit(%Job{} = job, timeout \\ 5_000) do
    pid = start_supervised!({JobServer, job.id})
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, timeout
    :ok
  end

  defp await_worker_exit(job_id) do
    case Horde.Registry.lookup(OpenAgents.HordeRegistry, {:work_job, job_id}) do
      [{pid, _value}] ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      [] ->
        :ok
    end
  end

  defp run_work_recovery do
    pid = start_supervised!({WorkRecovery, []})
    _state = :sys.get_state(pid)
    :ok
  end
end
