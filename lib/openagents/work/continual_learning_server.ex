defmodule OpenAgents.Work.ContinualLearningServer do
  @moduledoc """
  Supervised worker for one durable continual-learning run (CONTINUAL-001).

  Like `OpenAgents.Work.ScvServer`, this drives no model loop: it runs the
  bounded round loop in `OpenAgents.ContinualLearning.Runner` to completion in
  its own process, on the same row, statuses, Horde singleton, generation fence,
  recovery sweep, and report-into-conversation ending as every other kind. No
  second scheduler exists.

  An adopted run is not silently retrained. A worker that finds itself on a
  later generation stops the run as `interrupted`, which leaves the committed
  checkpoints in place for an explicit resume, so continuing a run is always an
  authorized act with its own receipt rather than a side effect of a restart.
  """

  # :transient — a crash on the same node is retried, and Horde relocates the
  # singleton to a survivor when its node dies. A clean finish is not restarted.
  use GenServer, restart: :transient

  alias OpenAgents.ContinualLearning
  alias OpenAgents.ContinualLearning.Job, as: LearningJob
  alias OpenAgents.ContinualLearning.Runner
  alias OpenAgents.Work

  # The runner enforces the stopping policy and the budget; this is the backstop
  # for a round loop that somehow outlives its admitted wall clock.
  @deadline_grace_ms 60_000

  def start_link(job_id) do
    GenServer.start_link(__MODULE__, job_id, name: via(job_id))
  end

  @impl true
  def init(job_id) do
    case Work.claim_for_run(job_id) do
      {:ok, %{generation: generation} = claimed} when generation > 1 ->
        _interrupted = interrupt(claimed)
        {:stop, :normal}

      {:ok, claimed} ->
        {:ok, %{job: claimed}, {:continue, :train}}

      {:error, _reason} ->
        {:stop, :normal}
    end
  end

  @impl true
  def handle_continue(:train, %{job: job}) do
    case learning_job_id(job) do
      nil ->
        _finished =
          Work.finish_job(job.id, "failed", error_code: "continual_learning_job_missing")

        {:stop, :normal, %{job: job}}

      learning_job_id ->
        deadline = Process.send_after(self(), :deadline, wall_clock_ms(job) + @deadline_grace_ms)

        task =
          Task.Supervisor.async_nolink(OpenAgents.ProviderTaskSupervisor, fn ->
            Runner.run(learning_job_id)
          end)

        {:noreply, %{job: job, learning_job_id: learning_job_id, deadline: deadline, task: task}}
    end
  end

  @impl true
  def handle_cast(:cancel, state) do
    _shutdown = Task.shutdown(state.task, :brutal_kill)
    _terminal = terminalize(state, "cancelled", "cancelled")

    _report =
      Work.append_report_delta(
        state.job,
        "Continual-learning job cancelled by the operator. Committed checkpoints and " <>
          "receipts are kept as evidence."
      )

    _finished = Work.finish_job(state.job.id, "cancelled", error_code: "cancelled")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({reference, result}, %{task: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    _timer = cancel_deadline(state)
    {status, report, usage, code} = summarize(result)
    _appended = Work.append_report_delta(state.job, report)
    _finished = Work.finish_job(state.job.id, status, error_code: code, usage: usage)
    {:stop, :normal, state}
  end

  def handle_info(:deadline, state) do
    _shutdown = Task.shutdown(state.task, :brutal_kill)
    _terminal = terminalize(state, "interrupted", "wall_clock_exceeded")

    _report =
      Work.append_report_delta(
        state.job,
        "Continual-learning job exceeded its admitted wall clock and was stopped. " <>
          "Resume it to continue from its last committed checkpoint."
      )

    _finished = Work.finish_job(state.job.id, "interrupted", error_code: "wall_clock_exceeded")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task: %{ref: reference}} = state) do
    _timer = cancel_deadline(state)
    _terminal = terminalize(state, "interrupted", "worker_exited")

    _report =
      Work.append_report_delta(
        state.job,
        "The continual-learning worker stopped unexpectedly. Resume the job to " <>
          "continue from its last committed checkpoint."
      )

    _finished = Work.finish_job(state.job.id, "interrupted", error_code: "worker_exited")
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── internal ───────────────────────────────────────────────────────────────

  defp interrupt(job) do
    with learning_job_id when is_binary(learning_job_id) <- learning_job_id(job),
         {:ok, learning_job} <- ContinualLearning.fetch(learning_job_id) do
      _receipt =
        ContinualLearning.record_receipt(learning_job, "refusal", %{
          "reason" => "adopted_after_restart",
          "detail" => "the run is resumable from its last committed checkpoint"
        })

      _terminal = ContinualLearning.terminalize(learning_job, "interrupted", "runtime_restarted")
    end

    Work.finish_job(job.id, "interrupted", error_code: "runtime_restarted")
  end

  defp terminalize(%{learning_job_id: learning_job_id}, status, code) do
    case ContinualLearning.fetch(learning_job_id) do
      {:ok, learning_job} -> ContinualLearning.terminalize(learning_job, status, code)
      {:error, reason} -> {:error, reason}
    end
  end

  defp learning_job_id(job) do
    case (job.delegation || %{})["continual_learning_job_id"] do
      value when is_binary(value) -> value
      _missing -> nil
    end
  end

  defp wall_clock_ms(job) do
    case (job.budget_snapshot || %{})["wall_clock_ms"] do
      value when is_integer(value) and value > 0 -> value
      _missing -> 900_000
    end
  end

  defp cancel_deadline(%{deadline: reference}) when is_reference(reference),
    do: Process.cancel_timer(reference)

  defp cancel_deadline(_state), do: :ok

  defp summarize({:ok, %LearningJob{} = learning_job}) do
    {work_status(learning_job.status), report_text(learning_job), usage(learning_job),
     learning_job.error_code}
  end

  defp summarize({:error, reason}) do
    {"failed", "Continual-learning job could not run: #{code(reason)}.", nil, code(reason)}
  end

  defp summarize(_other) do
    {"failed", "Continual-learning job ended without a terminal record.", nil,
     "continual_learning_failed"}
  end

  defp work_status("completed"), do: "completed"
  defp work_status("cancelled"), do: "cancelled"
  defp work_status("interrupted"), do: "interrupted"
  defp work_status("budget_exhausted"), do: "budget_exhausted"
  defp work_status(_status), do: "failed"

  defp report_text(%LearningJob{} = learning_job) do
    artifact = ContinualLearning.artifact(learning_job)

    header =
      "Continual-learning job #{learning_job.id} — #{human_status(learning_job.status)}. " <>
        "Objective version #{learning_job.objective_version} on #{learning_job.base_model_ref}. " <>
        "Rounds: #{learning_job.rounds_completed}."

    detail =
      if artifact do
        "Artifact digest #{artifact.artifact_digest}, model #{artifact.model_ref}, " <>
          "over #{length(artifact.checkpoint_digests)} checkpoints and " <>
          "#{length(artifact.dataset_bindings)} licensed datasets."
      else
        "No artifact was produced. Reason: #{learning_job.error_code || "unknown"}."
      end

    "#{header}\n\n#{detail}"
  end

  defp usage(%LearningJob{usage: usage}) when is_map(usage) and map_size(usage) > 0 do
    Map.take(usage, ["input_tokens", "output_tokens", "total_tokens"])
  end

  defp usage(_learning_job), do: nil

  defp human_status("completed"), do: "completed"
  defp human_status("cancelled"), do: "cancelled"
  defp human_status("interrupted"), do: "interrupted"
  defp human_status("budget_exhausted"), do: "stopped at its budget"
  defp human_status(other), do: "ended (#{other})"

  defp code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp code(_reason), do: "continual_learning_failed"

  defp via(job_id), do: {:via, Horde.Registry, {OpenAgents.HordeRegistry, {:work_job, job_id}}}
end
