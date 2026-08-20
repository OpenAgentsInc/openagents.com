defmodule OpenAgents.DeepWorkToolLoopTest do
  use OpenAgents.SarahDataCase
  @moduletag :skip
  import Ecto.Query

  alias OpenAgents.{Conversations, Turns, Work}
  alias OpenAgents.Conversations.Message
  alias OpenAgents.Work.Job

  setup do
    Application.put_env(:openagents, :test_tool_observer, self())
    on_exit(fn -> Application.delete_env(:openagents, :test_tool_observer) end)
    :ok
  end

  test "a text turn delegates to deep_work, acks immediately, and the report lands durably" do
    assert {:ok, conversation} = Conversations.ensure_conversation("deep-work-delegation")
    :ok = Work.subscribe(conversation.id)
    :ok = Conversations.subscribe(conversation)

    assert {:ok, %{turn: queued_turn}} =
             Conversations.create_turn(conversation, "[delegate-deep-work]")

    assert {:ok, pid} = Turns.start(queued_turn.id)
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000

    # The turn completed on the immediate acknowledgment, not on the job.
    turn = Conversations.get_turn!(queued_turn.id)
    assert turn.status == "completed"

    assistant = Repo.get!(Message, turn.assistant_message_id)

    assert assistant.content ==
             "I started a deep work job on that; the report will land here when it finishes."

    assert [delegate_step] =
             Repo.all(
               from(step in OpenAgents.Conversations.ToolStep,
                 where: step.turn_id == ^turn.id,
                 order_by: [asc: step.sequence]
               )
             )

    assert delegate_step.tool_name == "deep_work"
    assert delegate_step.status == "succeeded"
    assert delegate_step.side_effect_class == "read_only"
    assert ["work-job:" <> job_id] = delegate_step.target_receipt_refs
    assert delegate_step.result["status"] == "started"
    assert delegate_step.result["job_ref"] == "work-job:#{job_id}"

    # The delegated job runs to completion server-side.
    job = await_terminal_job(job_id)
    assert job.status == "completed"
    assert job.surface == "text"
    assert job.goal == "[deep-work-job]"
    assert job.conversation_id == conversation.id

    assert job.report ==
             "Deep work report: both lookarounds succeeded; found dw-alpha and dw-beta."

    assert [first, second] = Work.list_job_steps(job)
    assert first.tool_name == "recall_messages"
    assert first.status == "succeeded"
    assert second.status == "succeeded"

    # The report is a durable assistant message broadcast to the transcript.
    report_message = Repo.get!(Message, job.report_message_id)
    assert report_message.work_job_id == job.id
    report_message_id = report_message.id
    assert_receive {:message_updated, %Message{id: ^report_message_id}}

    # A later turn composes the report as ordinary durable evidence.
    assert Enum.any?(
             Conversations.provider_messages(conversation.id),
             &(&1.role == "assistant" and &1.content == job.report)
           )
  end

  test "a job cannot recurse into another deep_work job" do
    assert {:ok, conversation} = Conversations.ensure_conversation("deep-work-no-recursion")
    owner = Conversations.get_conversation_owner!(conversation)

    assert {:ok, job} =
             Work.create_job(%{
               conversation_id: conversation.id,
               owner_visitor_id: owner.id,
               surface: "text",
               goal: "[delegate-deep-work]"
             })

    pid = start_supervised!({OpenAgents.Work.JobServer, job.id})
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000

    finished = Work.get_job!(job.id)
    assert Job.terminal?(finished)
    assert finished.report != nil and finished.report != ""

    assert [step] = Work.list_job_steps(finished)
    assert step.tool_name == "deep_work"
    assert step.status == "refused"
    assert step.error["code"] == "work_recursion_refused"

    # No second job was created.
    assert Repo.aggregate(from(j in Job, where: j.conversation_id == ^conversation.id), :count) ==
             1
  end

  defp await_terminal_job(job_id, timeout \\ 5_000) do
    receive do
      {:work_job_updated, %Job{id: ^job_id} = job} ->
        if Job.terminal?(job), do: job, else: await_terminal_job(job_id, timeout)

      {:work_job_updated, %Job{}} ->
        await_terminal_job(job_id, timeout)
    after
      timeout ->
        flunk("work job #{job_id} did not reach a terminal state")
    end
  end
end
