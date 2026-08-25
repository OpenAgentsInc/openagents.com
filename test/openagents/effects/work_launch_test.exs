defmodule OpenAgents.Effects.WorkLaunchTest do
  @moduledoc """
  The converted call site: a work job's worker launch (EFFECT-001, issue #202).

  Before the outbox, `OpenAgents.Work.start_job/1` committed the job row and
  then asked Horde for a worker, from the same process on the same node. A
  crash in that gap left a committed `queued` job that nothing was executing,
  and nothing noticed: `OpenAgents.Work.recover_interrupted_jobs/0` sweeps at
  boot and never after, so the job sat until that node restarted.

  What these tests assert is the fix, not the happy path someone hopes for: the
  launch is committed with the job, so it survives the gap; a job whose inline
  launch never ran is still launched, by any node's worker; and delivering it
  twice starts one worker, not two.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Conversations
  alias OpenAgents.Effects
  alias OpenAgents.Effects.Handlers.WorkLaunch
  alias OpenAgents.Effects.Worker
  alias OpenAgents.Work
  alias OpenAgents.Work.Job

  describe "admission" do
    test "a started job commits its launch in the same transaction" do
      {_conversation, job} = start_job("effect-launch-commit")

      assert [effect] = Effects.for_source("work_job", job.id)
      assert effect.kind == "work.launch_worker"
      assert effect.payload == %{"job_id" => job.id, "worker" => "job"}
      assert effect.source_kind == "work_job"
      assert effect.source_id == job.id
      assert effect.payload_digest =~ ~r/^sha256:[0-9a-f]{64}$/

      # The inline launch succeeded, so the ordinary path retires its own
      # effect: the outbox wrote one row and closed it.
      assert effect.status == "done"
      assert effect.completed_at != nil
    end

    test "a refused job leaves neither a job row nor a launch owed" do
      {:ok, conversation} = Conversations.ensure_conversation("effect-launch-refused")
      owner = Conversations.get_conversation_owner!(conversation)
      before_jobs = Repo.aggregate(Job, :count)

      assert {:error, %Ecto.Changeset{}} =
               Work.start_job(%{
                 conversation_id: conversation.id,
                 owner_visitor_id: owner.id,
                 surface: "carrier-pigeon",
                 goal: "an inadmissible surface"
               })

      # The transaction that would have written the launch never committed, so
      # the outbox owes nothing for an intent that was refused.
      assert Repo.aggregate(Job, :count) == before_jobs
      assert Effects.counts() == %{}
    end

    test "each kind names the worker its launch effect must start" do
      assert WorkLaunch.worker_names() == ~w(continual_learning delegation job scv)
      assert {:ok, OpenAgents.Work.JobServer} = WorkLaunch.worker("job")
      assert {:error, :unknown_worker} = WorkLaunch.worker("Elixir.System")
    end
  end

  describe "delivery" do
    test "a launch the inline attempt never made is delivered by the outbox" do
      {job, stranded} = queued_job_owed_a_launch("effect-launch-stranded")
      assert stranded.status == "pending"

      recording_launch_handler()

      assert %{claimed: 1, completed: 1} = Worker.run_once(identity: "worker-outbox")

      assert_received {:launch_requested, server, job_id}
      assert server == OpenAgents.Work.JobServer
      assert job_id == job.id
      assert Effects.get(stranded.id).status == "done"
    end

    test "a redelivered launch starts one worker, not two" do
      {job, _stranded} = queued_job_owed_a_launch("effect-launch-redelivered")

      recording_launch_handler()

      assert %{completed: 1} = Worker.run_once(identity: "worker-a")
      assert_received {:launch_requested, _server, delivered_job_id}
      assert delivered_job_id == job.id

      # The effect is done, so a second pass has nothing to deliver. The
      # singleton guarantee behind `ensure_worker/2` is the second line of
      # defence, not the first.
      assert %{claimed: 0, completed: 0} = Worker.run_once(identity: "worker-b")
      refute_received {:launch_requested, _other_server, _other_job}
    end

    test "a job that finished before its launch was delivered needs no worker" do
      {job, stranded} = queued_job_owed_a_launch("effect-launch-terminal")

      {:ok, _finished} = Work.finish_job(job.id, "cancelled", error_code: "cancelled")

      recording_launch_handler()

      assert %{claimed: 1, completed: 1} = Worker.run_once(identity: "worker-a")

      # Nothing owed is not a failure to retry: the effect completes and no
      # worker is asked for.
      refute_received {:launch_requested, _server, _job_id}
      assert Effects.get(stranded.id).status == "done"
    end

    test "a launch for a job that no longer exists completes rather than retrying forever" do
      {:ok, effect} =
        Effects.enqueue("work.launch_worker", %{
          payload: %{"job_id" => Ecto.UUID.generate(), "worker" => "job"},
          source_kind: "work_job",
          source_id: Ecto.UUID.generate()
        })

      assert %{claimed: 1, completed: 1} = Worker.run_once(identity: "worker-a")
      assert Effects.get(effect.id).status == "done"
    end

    test "a launch payload naming no worker is refused, not run" do
      {:ok, effect} =
        Effects.enqueue("work.launch_worker", %{
          payload: %{"job_id" => Ecto.UUID.generate()},
          source_kind: "work_job",
          source_id: "malformed"
        })

      assert [claimed] = Effects.claim_batch("worker-a")
      assert :error = Worker.dispatch(claimed)
      assert Effects.get(effect.id).last_error =~ "invalid_payload"
    end
  end

  describe "crash boundary" do
    test "the launch effect survives a failed inline placement" do
      remove_horde_supervisor()
      on_exit(fn -> restore_horde_supervisor() end)

      _fake =
        start_supervised!({OpenAgents.Effects.WorkLaunchTest.CrashingHorde, []})

      recording_launch_handler()

      {:ok, conversation} =
        Conversations.ensure_conversation("effect-launch-failed-placement")

      owner = Conversations.get_conversation_owner!(conversation)

      assert {:error, :worker_start_failed} =
               Work.start_job(%{
                 conversation_id: conversation.id,
                 owner_visitor_id: owner.id,
                 surface: "text",
                 goal: "a job whose worker could not be placed"
               })

      assert [job] = Work.recent_jobs(conversation, 1)
      assert job.status == "queued"
      job_id = job.id

      assert [effect] = Effects.for_source("work_job", job_id)
      assert effect.kind == "work.launch_worker"
      assert effect.payload == %{"job_id" => job_id, "worker" => "job"}
      assert effect.source_kind == "work_job"
      assert effect.source_id == job_id
      assert effect.status == "pending"

      assert %{claimed: 1, completed: 1} =
               Worker.run_once(identity: "worker-outbox")

      assert_received {:launch_requested, OpenAgents.Work.JobServer, ^job_id}
      assert Effects.get(effect.id).status == "done"
    end
  end

  # The ordinary path, run to a terminal job so no worker outlives the test.
  defp start_job(browser_key) do
    {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    owner = Conversations.get_conversation_owner!(conversation)
    :ok = Work.subscribe(conversation.id)

    {:ok, job} =
      Work.start_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "just summarize the plan"
      })

    await_terminal(job.id)
    {conversation, job}
  end

  defp await_terminal(job_id) do
    receive do
      {:work_job_updated, %Job{id: ^job_id, status: status}}
      when status in ["completed", "failed", "interrupted", "budget_exhausted", "cancelled"] ->
        :ok

      {:work_job_updated, %Job{id: ^job_id}} ->
        await_terminal(job_id)
    after
      10_000 -> flunk("the started job never reached a terminal status")
    end
  end

  # The state a crash between commit and launch leaves behind: a committed
  # `queued` job row and, committed with it, the launch nobody ran. The shape
  # of the effect is not invented here — the admission test above asserts that
  # `Work.start_job/1` writes exactly this row.
  defp queued_job_owed_a_launch(browser_key) do
    {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "a job whose worker was never started"
      })

    {:ok, effect} =
      Effects.enqueue("work.launch_worker", %{
        payload: %{"job_id" => job.id, "worker" => "job"},
        source_kind: "work_job",
        source_id: job.id
      })

    assert job.status == "queued"
    {job, effect}
  end

  defp recording_launch_handler do
    Application.put_env(:openagents, :effects,
      handlers: %{"work.launch_worker" => OpenAgents.Effects.WorkLaunchTest.RecordingLaunch}
    )

    Application.put_env(:openagents, :effects_launch_observer, self())

    on_exit(fn ->
      Application.delete_env(:openagents, :effects)
      Application.delete_env(:openagents, :effects_launch_observer)
    end)
  end

  defp remove_horde_supervisor do
    remove_horde_supervisor(5)
  end

  defp remove_horde_supervisor(0) do
    :ok
  end

  defp remove_horde_supervisor(retries) do
    case Supervisor.terminate_child(OpenAgents.RuntimeSupervisor, OpenAgents.HordeSupervisor) do
      :ok ->
        case Supervisor.delete_child(OpenAgents.RuntimeSupervisor, OpenAgents.HordeSupervisor) do
          :ok ->
            :ok

          {:error, :running} ->
            remove_horde_supervisor(retries - 1)

          _ ->
            :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp restore_horde_supervisor do
    _ = Supervisor.terminate_child(OpenAgents.RuntimeSupervisor, OpenAgents.HordeSupervisor)
    _ = Supervisor.delete_child(OpenAgents.RuntimeSupervisor, OpenAgents.HordeSupervisor)

    horde_spec = {
      Horde.DynamicSupervisor,
      name: OpenAgents.HordeSupervisor,
      strategy: :one_for_one,
      members: :auto,
      process_redistribution: :passive,
      delta_crdt_options: [sync_interval: 150]
    }

    case Supervisor.restart_child(OpenAgents.RuntimeSupervisor, OpenAgents.HordeSupervisor) do
      {:ok, _pid} ->
        :ok

      {:ok, _pid, _info} ->
        :ok

      {:error, :not_found} ->
        case Supervisor.start_child(OpenAgents.RuntimeSupervisor, horde_spec) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :already_started} -> :ok
          _ -> :ok
        end

      _ ->
        :ok
    end
  end
end
