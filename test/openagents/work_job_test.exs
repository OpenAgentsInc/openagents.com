defmodule OpenAgents.WorkJobTest do
  use OpenAgents.SarahDataCase
  alias OpenAgents.{Conversations, Work}
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

    send(tool_pid, :release_test_tool)

    before_recovery = Work.get_job!(job.id)
    assert before_recovery.status == "running"

    # Recovery restarts the worker: it re-claims through the generation fence
    # (adopt) and continues the work — the job is NOT finalized interrupted.
    assert :ok = Work.recover_interrupted_jobs()

    # The restarted worker adopted the row through the fence (generation bumped)
    # and drove the job to a REAL terminal state — never the buried
    # `interrupted`/`runtime_restarted`. (Under the test stub the resumed
    # provider run ends `failed` quickly — the stub binds to the test process —
    # which is still an honest terminal outcome produced by actual resumed
    # work, not a burial.)
    final = wait_for_terminal(job.id)
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

    send(tool_pid, :release_test_tool)
    final = wait_for_terminal(job.id)
    refute final.status == "interrupted"
  end

  defp wait_for_terminal(job_id, attempts \\ 100) do
    job = Work.get_job!(job_id)

    cond do
      job.status in Job.terminal_statuses() ->
        job

      attempts <= 0 ->
        flunk("job never reached a terminal status (stuck #{job.status})")

      true ->
        Process.sleep(100)
        wait_for_terminal(job_id, attempts - 1)
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
    {:ok, conversation} = Conversations.ensure_conversation("deleg-report-browser")
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "Delegate to claude on devin-test: refactor the input bar",
        kind: "delegation",
        delegation: %{"agent_id" => "claude", "machine_name" => "devin-test"}
      })

    {:ok, finished} = Work.finish_job(job.id, "interrupted", error_code: "runtime_restarted")

    assert finished.status == "interrupted"

    assert finished.report =~
             "Delegation to claude on devin-test was interrupted by a server restart"

    refute finished.report =~ "Deep work job"
    refute finished.report =~ "no tool calls had completed"
  end

  test "cancel_job finishes a queued job as cancelled with an honest report" do
    {:ok, conversation} = Conversations.ensure_conversation("deleg-cancel-browser")
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "Delegate to claude on devin-test: refactor the input bar",
        kind: "delegation",
        delegation: %{"agent_id" => "claude", "machine_name" => "devin-test"}
      })

    assert {:ok, finished} = Work.cancel_job(job.id)
    assert finished.status == "cancelled"
    assert finished.error_code == "cancelled"
    assert finished.report =~ "was cancelled"
  end

  test "checkpoint_delegation_session persists the session id only for the live generation" do
    {:ok, conversation} = Conversations.ensure_conversation("deleg-ckpt-browser")
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "Delegate to claude on devin-test: do work",
        kind: "delegation",
        delegation: %{"agent_id" => "claude", "machine_name" => "devin-test"}
      })

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

  test "boot recovery records a degraded incident for each interrupted job" do
    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: "deleg-recover",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "Delegate to claude on devin-test: do work",
        kind: "delegation",
        delegation: %{"agent_id" => "claude", "machine_name" => "devin-test"}
      })

    :ok = Work.recover_interrupted_jobs()

    # Resume-first recovery still restarts this delegation's worker; with no
    # machine connected it finishes honestly (machine_offline) — let it settle
    # so the async worker never outlives the test's DB sandbox.
    final = wait_for_terminal(job.id)
    refute final.status == "interrupted"

    incidents = OpenAgents.Incidents.list_recent(owner.user_id)
    incident = Enum.find(incidents, &(&1.code == "runtime_restarted"))
    assert incident
    # A restart is degraded, not anomalous — recorded, never auto-escalated.
    assert incident.severity == "degraded"
    assert incident.surface == "delegation"
  end

  defp create_job(browser_key, goal) do
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    owner = Conversations.get_conversation_owner!(conversation)

    assert {:ok, job} =
             Work.create_job(%{
               conversation_id: conversation.id,
               owner_visitor_id: owner.id,
               surface: "text",
               goal: goal
             })

    {conversation, job}
  end

  defp run_job_to_exit(%Job{} = job, timeout \\ 5_000) do
    pid = start_supervised!({JobServer, job.id})
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, timeout
    :ok
  end
end
