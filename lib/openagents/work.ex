defmodule OpenAgents.Work do
  @moduledoc """
  Durable delegated deep-work jobs (`deep_work.v1`, RLM Phase 1).

  A job moves multi-step tool work out of the fragile text/voice response
  cycle into a budgeted, recoverable, server-side loop. PostgreSQL is
  authoritative: the job row and its ordered steps are committed before any
  provider continuation, every terminal path stores a non-empty (possibly
  partial) report, and startup recovery RESUMES orphaned jobs through the
  generation fence (finalizing `interrupted` only when the worker cannot
  start). See INVARIANTS.md WORK-001.
  """

  import Ecto.Query
  require Logger

  alias Ecto.Multi
  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.{Conversation, Message, Visitor}
  alias OpenAgents.Memory.LexicalRecall
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo
  alias OpenAgents.Work.{Job, JobStep}

  @active_statuses ~w(queued running)
  @maximum_steps 64

  @doc """
  Creates a queued job and starts its supervised worker.

  Returns quickly so the calling turn or voice response can acknowledge with
  a job reference while the work continues server-side.
  """
  def start_job(attributes) when is_map(attributes) do
    admit_and_launch(attributes, "job")
  end

  @doc """
  Stops one active job. The worker is asked to cancel; if it is already gone
  the job is finished as `cancelled` here. Already-terminal jobs are returned
  unchanged.
  """
  def cancel_job(job_id) when is_binary(job_id) do
    # The job runs as a Horde cluster singleton (M1); look it up cluster-wide by
    # its OpenAgents.Cluster.Registry key, wherever in the cluster it currently lives.
    case OpenAgents.Cluster.Registry.lookup(OpenAgents.HordeRegistry, {:work_job, job_id}) do
      [{pid, _value}] ->
        GenServer.cast(pid, :cancel)
        {:ok, :stopping}

      [] ->
        finish_job(job_id, "cancelled", error_code: "cancelled")
    end
  end

  @doc "Cancels every active delegation job in a conversation, optionally except one."
  def cancel_active_delegations(conversation_id, except_id \\ nil)
      when is_binary(conversation_id) do
    jobs =
      Repo.all(
        from(job in Job,
          where:
            job.conversation_id == ^conversation_id and job.kind == "delegation" and
              job.status in ^@active_statuses
        )
      )

    Enum.each(jobs, fn job ->
      if job.id != except_id, do: cancel_job(job.id)
    end)

    :ok
  end

  @doc """
  Creates a queued `delegation` job and starts its supervised delegation worker.

  Returns quickly so the calling turn can acknowledge with a job reference while
  the delegation runs in the background — several run at once, each streaming to
  the live rail and reporting back when done.
  """
  def start_delegation(attributes) when is_map(attributes) do
    attributes
    |> Map.put(:kind, "delegation")
    |> admit_and_launch("delegation")
  end

  @doc """
  Start a durable coding job (#122): the ordinary JobServer loop under the
  coding-lieutenant role with the repository tool family, editing a per-job
  clone of Sarah's own forge under SELF-EDIT-001.
  """
  def start_coding(attributes) when is_map(attributes) do
    start_job(Map.put(attributes, :kind, "coding"))
  end

  @doc """
  Start a durable SCV deployment (SCV-001): one bounded OpenCode run on our own
  capacity, driven by `OpenAgents.Work.ScvServer` rather than by the model
  loop, sharing the same row, statuses, fence, recovery sweep, and
  report-into-conversation ending as every other kind.

  Admission belongs to `OpenAgents.SCV.Deployments.start/2`; this only creates
  the row and starts the worker.
  """
  def start_scv(attributes) when is_map(attributes) do
    attributes
    |> Map.put(:kind, "scv")
    |> admit_and_launch("scv")
  end

  @doc """
  Start a durable continual-learning run (CONTINUAL-001): the bounded round loop
  in `OpenAgents.ContinualLearning.Runner`, driven by
  `OpenAgents.Work.ContinualLearningServer` on the same row, statuses, fence,
  and recovery sweep as every other kind.

  Admission belongs to `OpenAgents.ContinualLearning.start/2`; this only creates
  the row and starts the worker.
  """
  def start_continual_learning(attributes) when is_map(attributes) do
    attributes
    |> Map.put(:kind, "continual_learning")
    |> admit_and_launch("continual_learning")
  end

  # Commit the job and the launch it is owed in one transaction, then try the
  # launch inline (EFFECT-001).
  #
  # The transaction is the point. Before the outbox, the job row committed and
  # the Horde child was started afterwards, from the same process, on the same
  # node; a crash in that gap left a committed `queued` job that nothing was
  # executing and nothing would notice until that node booted again, because
  # `recover_interrupted_jobs/0` runs at boot and never after. Now the effect
  # row commits with the job, so any node's outbox worker can start what this
  # one promised.
  #
  # The inline launch stays because it is fast and almost always succeeds; the
  # outbox is what makes it safe for it to fail. On success the effect is
  # completed here, so the ordinary path writes exactly one extra row and
  # retires it. On failure the effect stays pending and the outbox retries it,
  # which is why the job is no longer failed with `worker_start_failed` on the
  # spot: a transient placement error is not a dead job any more.
  defp admit_and_launch(attributes, worker_name) do
    {:ok, server} = OpenAgents.Effects.Handlers.WorkLaunch.worker(worker_name)

    with {:ok, %{job: job, effect: effect}} <- commit_job_with_launch(attributes, worker_name) do
      broadcast_job(job)

      case start_worker(server, job.id) do
        {:ok, _pid} ->
          {:ok, _completed} = OpenAgents.Effects.complete(effect)
          {:ok, job}

        {:error, reason} ->
          Logger.warning(
            "work_launch_deferred job=#{job.id} worker=#{worker_name} " <>
              "code=#{OpenAgents.Effects.error_code(reason)}"
          )

          {:error, reason}
      end
    end
  end

  defp commit_job_with_launch(attributes, worker_name) do
    result =
      Repo.transaction(fn ->
        with {:ok, job} <- insert_job(attributes),
             {:ok, effect} <- enqueue_launch(job, worker_name) do
          %{job: job, effect: effect}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, admitted} -> {:ok, admitted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_launch(%Job{id: job_id}, worker_name) do
    OpenAgents.Effects.enqueue("work.launch_worker", %{
      payload: %{"job_id" => job_id, "worker" => worker_name},
      source_kind: "work_job",
      source_id: job_id
    })
  end

  @doc """
  Start a job's worker, reporting an already-running singleton as success.

  Public because the effect outbox's `OpenAgents.Effects.Handlers.WorkLaunch`
  calls it to deliver a launch this node did not complete inline.
  """
  @spec ensure_worker(module(), String.t()) :: {:ok, pid() | :ignore} | {:error, term()}
  def ensure_worker(server, job_id) when is_atom(server) and is_binary(job_id),
    do: start_worker(server, job_id)

  # Start a job's worker as a cluster-wide singleton under Horde. Horde routes
  # the child to whichever member `choose_node` picks and relocates it to a
  # survivor if that node dies. `{:already_started, pid}` is success: the
  # singleton is already running somewhere in the cluster (e.g. a retry, or a
  # relocation race), which is exactly the guarantee we want.
  defp start_worker(server, job_id) do
    case OpenAgents.Cluster.DynamicSupervisor.start_child(
           OpenAgents.HordeSupervisor,
           {server, job_id}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      :ignore -> {:ok, :ignore}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def create_job(attributes) when is_map(attributes) do
    case insert_job(attributes) do
      {:ok, job} ->
        broadcast_job(job)
        {:ok, job}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # The insert alone. `admit_and_launch/2` needs it without the broadcast,
  # because a broadcast inside the admitting transaction would announce a job
  # a rollback could still take away.
  defp insert_job(attributes) do
    %Job{}
    |> Job.create_changeset(attributes)
    |> Repo.insert()
  end

  def get_job!(job_id), do: Repo.get!(Job, job_id)

  def get_job(job_id), do: Repo.get(Job, job_id)

  def get_job_owner!(%Job{owner_visitor_id: owner_visitor_id}),
    do: Repo.get!(Visitor, owner_visitor_id)

  @doc """
  The most recent jobs for a conversation, newest first, bounded.

  A read-only sidebar projection over the durable job rows; live updates ride
  the existing `{:work_job_updated, job}` broadcasts rather than polling.
  """
  def recent_jobs(%Conversation{id: conversation_id}, limit)
      when is_integer(limit) and limit > 0 do
    Repo.all(
      from(job in Job,
        where: job.conversation_id == ^conversation_id,
        order_by: [desc: job.inserted_at, desc: job.id],
        limit: ^limit
      )
    )
  end

  def list_job_steps(%Job{id: job_id}) do
    Repo.all(
      from(step in JobStep,
        where: step.work_job_id == ^job_id,
        order_by: [asc: step.sequence]
      )
    )
  end

  @doc "Subscribes to job lifecycle projections for one conversation."
  def subscribe(conversation_id) when is_binary(conversation_id) do
    Phoenix.PubSub.subscribe(OpenAgents.PubSub, work_topic(conversation_id))
  end

  @doc """
  Captures the recall high-water reference for a job: the latest complete
  message at job start, so the job's recall tools see the same bounded
  conversation snapshot discipline as a turn (MEMORY-004).
  """
  def capture_recall_ref(conversation_id, job_id) do
    # `job_id` is not a message ID, so the exclusion filter excludes nothing:
    # the ref is simply the latest complete message when the job began.
    case LexicalRecall.capture_ref(Repo, conversation_id, job_id) do
      {:ok, ref} -> ref
      {:error, _reason} -> nil
    end
  end

  @doc """
  Claims a job for the current node and returns it ready to run.

  This is the handoff-safe replacement for the queued-only `mark_job_running`.
  It transitions `queued -> running` on a fresh start, and **adopts** a job that
  is already `running` (its previous owner node died and Horde relocated the
  singleton here) by taking ownership without resetting `started_at`. A terminal
  job is refused so a relocated/duplicate worker stops cleanly instead of
  re-running finished work.

  Every claim bumps `generation` and records `owner_node`, over a
  `SELECT ... FOR UPDATE` row lock, so the linearizable Postgres row is the
  ownership authority (the fence): the highest generation is the live owner.
  """
  def claim_for_run(job_id, attributes \\ %{}) when is_map(attributes) do
    result =
      Repo.transaction(fn ->
        locked_job = Repo.get_for_update!(Job, job_id)

        cond do
          locked_job.status in Job.terminal_statuses() ->
            Repo.rollback(:work_job_terminal)

          locked_job.status not in ~w(queued running) ->
            Repo.rollback(:work_job_unclaimable)

          true ->
            base = %{
              owner_node: to_string(node()),
              generation: (locked_job.generation || 0) + 1
            }

            base =
              if locked_job.status == "queued",
                do: Map.merge(base, %{status: "running", started_at: DateTime.utc_now()}),
                else: base

            locked_job
            |> Job.lifecycle_changeset(Map.merge(attributes, base))
            |> update_or_rollback()
        end
      end)

    case result do
      {:ok, running_job} ->
        broadcast_job(running_job)
        {:ok, running_job}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Moves a queued job to running and pins its captured identity fields."
  def mark_job_running(%Job{} = job, attributes) when is_map(attributes) do
    result =
      Repo.transaction(fn ->
        locked_job = Repo.get_for_update!(Job, job.id)

        if locked_job.status != "queued" do
          Repo.rollback(:work_job_not_queued)
        end

        locked_job
        |> Job.lifecycle_changeset(
          Map.merge(attributes, %{status: "running", started_at: DateTime.utc_now()})
        )
        |> update_or_rollback()
      end)

    case result do
      {:ok, running_job} ->
        broadcast_job(running_job)
        {:ok, running_job}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Durably appends streamed report text so a partial report survives restarts."
  def append_report_delta(%Job{} = job, delta) when is_binary(delta) do
    Repo.transaction(fn ->
      locked_job = Repo.get_for_update!(Job, job.id)

      if locked_job.status != "running" do
        Repo.rollback(:work_job_not_running)
      end

      appended = truncate_utf8((locked_job.report || "") <> delta, Job.maximum_report_bytes())

      locked_job
      |> Job.lifecycle_changeset(%{report: appended})
      |> update_or_rollback()
    end)
  end

  @doc "Commits one requested step before execution; duplicate call IDs return the existing row."
  def request_job_step(%Job{} = job, attributes) when is_map(attributes) do
    raw_arguments = Map.get(attributes, :raw_arguments)

    with :ok <- validate_raw_arguments(raw_arguments),
         {:ok, argument_digest} <- argument_digest(raw_arguments) do
      result =
        Repo.transaction(fn ->
          locked_job = Repo.get_for_update!(Job, job.id)

          if locked_job.status != "running" do
            Repo.rollback(:work_job_not_accepting_steps)
          end

          case Repo.get_by(JobStep,
                 work_job_id: locked_job.id,
                 provider_call_id: Map.fetch!(attributes, :provider_call_id)
               ) do
            %JobStep{} = existing_step ->
              {existing_step, :existing}

            nil ->
              sequence =
                Repo.aggregate(
                  from(step in JobStep, where: step.work_job_id == ^locked_job.id),
                  :max,
                  :sequence
                ) || 0

              if sequence >= @maximum_steps do
                Repo.rollback(:work_job_step_limit_reached)
              end

              step =
                %JobStep{}
                |> JobStep.requested_changeset(%{
                  work_job_id: locked_job.id,
                  sequence: sequence + 1,
                  provider_call_id: Map.fetch!(attributes, :provider_call_id),
                  provider_item_id: Map.fetch!(attributes, :provider_item_id),
                  provider_response_id: Map.fetch!(attributes, :provider_response_id),
                  tool_name: Map.fetch!(attributes, :tool_name),
                  tool_version: Map.fetch!(attributes, :tool_version),
                  module_id: Map.fetch!(attributes, :module_id),
                  module_artifact_digest: Map.get(attributes, :module_artifact_digest),
                  catalog_digest: Map.fetch!(attributes, :catalog_digest),
                  argument_digest: argument_digest,
                  status: "requested",
                  requested_at: DateTime.utc_now()
                })
                |> insert_or_rollback()

              {step, :created}
          end
        end)

      case result do
        {:ok, {step, disposition}} -> {:ok, step, disposition}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Atomically claims one committed step for execution."
  def start_job_step(%JobStep{} = step) do
    Repo.transaction(fn ->
      locked_step = Repo.get_for_update!(JobStep, step.id)

      case locked_step.status do
        "requested" ->
          running_step =
            locked_step
            |> JobStep.running_changeset(%{status: "running", started_at: DateTime.utc_now()})
            |> update_or_rollback()

          {running_step, :started}

        "running" ->
          {locked_step, :already_running}

        _terminal ->
          Repo.rollback(:work_job_step_is_terminal)
      end
    end)
    |> case do
      {:ok, {running_step, disposition}} -> {:ok, running_step, disposition}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stores one immutable typed outcome for a step; identical retries are idempotent."
  def complete_job_step(%JobStep{} = step, %{"schema" => "sarah.tool_outcome.v1"} = outcome) do
    with :ok <- validate_outcome(step, outcome),
         {:ok, outcome_digest} <- Canonical.digest(outcome) do
      Repo.transaction(fn ->
        locked_step = Repo.get_for_update!(JobStep, step.id)

        if locked_step.status in ~w(requested running) do
          locked_step
          |> JobStep.terminal_changeset(%{
            status: outcome["status"],
            outcome_digest: outcome_digest,
            result: outcome["result"],
            error: outcome["error"],
            usage: Map.get(outcome, "usage", %{"invocations" => 1}),
            executor_id: get_in(outcome, ["executor_ref", "id"]),
            executor_disclosure: get_in(outcome, ["executor_ref", "disclosure"]),
            target_receipt_refs: outcome["target_receipt_refs"],
            attribution_refs: outcome["attribution_refs"],
            completed_at: DateTime.utc_now()
          })
          |> update_or_rollback()
        else
          if locked_step.outcome_digest == outcome_digest,
            do: locked_step,
            else: Repo.rollback(:work_job_step_outcome_conflict)
        end
      end)
    end
  end

  def complete_job_step(%JobStep{}, _outcome), do: {:error, :invalid_tool_outcome}

  @doc "Rereads the committed terminal step and builds the provider continuation payload."
  def step_continuation_output(%JobStep{id: step_id}) do
    step = Repo.get!(JobStep, step_id)

    if step.status in JobStep.terminal_statuses() and is_binary(step.outcome_digest) do
      {:ok,
       %{
         "schema" => "sarah.tool_continuation.v1",
         "call_id" => step.provider_call_id,
         "outcome_digest" => step.outcome_digest,
         "output" => %{
           "status" => step.status,
           "result" => step.result,
           "error" => step.error,
           "executor" => %{
             "id" => step.executor_id,
             "disclosure" => step.executor_disclosure
           },
           "target_receipt_refs" => step.target_receipt_refs,
           "attribution_refs" => step.attribution_refs,
           "usage" => step.usage
         }
       }}
    else
      {:error, :work_job_step_not_terminal}
    end
  end

  @doc """
  Finishes a job on one of its terminal statuses.

  Composes the durable report (accumulated text, or an honest fallback built
  from committed step evidence), terminates any active steps, persists the
  report as a durable assistant conversation message, and broadcasts so the
  transcript renders it. If a live voice session exists for the conversation,
  the bounded report is injected into the live provider conversation
  best-effort after commit.
  """
  def finish_job(job_id, status, options \\ [])
      when status in ~w(completed failed interrupted budget_exhausted cancelled) and
             is_list(options) do
    error_code = Keyword.get(options, :error_code)
    usage = Keyword.get(options, :usage)
    tool_call_count = Keyword.get(options, :tool_call_count)
    continuation_count = Keyword.get(options, :continuation_count)
    now = DateTime.utc_now()

    result =
      Multi.new()
      |> Multi.run(:locked_job, fn repo, _changes ->
        {:ok, repo.get_for_update!(Job, job_id)}
      end)
      |> Multi.run(:admission, fn _repo, %{locked_job: locked_job} ->
        if locked_job.status in @active_statuses,
          do: {:ok, :active},
          else: {:error, {:already_terminal, locked_job}}
      end)
      |> Multi.run(:steps, fn repo, %{locked_job: locked_job} ->
        terminate_active_steps(repo, locked_job.id, interruption_status(status), error_code, now)
      end)
      |> Multi.run(:report, fn repo, %{locked_job: locked_job} ->
        {:ok, compose_report(repo, locked_job, status)}
      end)
      |> Multi.run(:message, fn repo, %{locked_job: locked_job, report: report} ->
        %Message{}
        |> Message.changeset(%{
          conversation_id: locked_job.conversation_id,
          role: "assistant",
          content: report,
          status: "complete",
          work_job_id: locked_job.id
        })
        |> repo.insert()
      end)
      |> Multi.run(:job, fn repo, %{locked_job: locked_job, report: report, message: message} ->
        locked_job
        |> Job.lifecycle_changeset(
          %{
            status: status,
            report: report,
            error_code: normalize_error_code(error_code),
            usage: usage,
            report_message_id: message.id,
            completed_at: now
          }
          |> maybe_put(:tool_call_count, tool_call_count)
          |> maybe_put(:continuation_count, continuation_count)
        )
        |> repo.update()
      end)
      |> Multi.run(:coding_grant, fn _repo, %{job: job} ->
        OpenAgents.Work.Coding.settle_grant(job)
      end)
      |> Multi.run(:scv_grant, fn _repo, %{job: job} ->
        OpenAgents.Work.Scv.settle_grant(job)
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{job: job, message: message}} ->
        Conversations.notify_message_updated(message)
        broadcast_job(job)
        _injection = deliver_live_voice_report(job, message)
        # Kind-specific terminal cleanup (this path runs even when the worker
        # died): a coding job removes its clone and settles its grant, and an
        # SCV deployment removes its disposable workspace.
        :ok = OpenAgents.Work.Coding.on_terminal(job)
        :ok = OpenAgents.Work.Scv.on_terminal(job)
        {:ok, job}

      {:error, :admission, {:already_terminal, job}, _changes} ->
        {:ok, job}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  RESUMES jobs left active by a runtime restart instead of burying them (#97).

  For each active job, restart its supervised worker: the worker's own
  `claim_for_run/2` adopts the row (generation fence), and a delegation resumes
  the live ACP session by its durably checkpointed id. On a fleet node this is
  also safe for jobs still running elsewhere — the Horde singleton answers
  `already_started` and nothing is disturbed. A restart is still recorded as a
  degraded incident (queryable evidence of "what happened here"). A transient
  worker startup failure retries in the supervised background while Horde and
  Raft converge. Only a job that exhausts the bounded recovery window becomes
  `interrupted`.
  """
  def recover_interrupted_jobs(options \\ []) do
    start_worker = Keyword.get(options, :start_worker, &start_worker/2)
    schedule_retry = Keyword.get(options, :schedule_retry, &schedule_recovery_retry/3)
    jobs = Repo.all(from(job in Job, where: job.status in ^@active_statuses))

    Enum.each(jobs, fn job ->
      _incident = record_interruption_incident(job)

      case start_worker.(worker_module(job.kind), job.id) do
        {:ok, _pid_or_ignore} ->
          :ok

        {:error, reason} ->
          schedule_retry.(job, reason, start_worker)
      end
    end)

    :ok
  end

  @recovery_retry_delays_ms [250, 500, 1_000, 2_000, 4_000, 8_000, 15_000]

  defp schedule_recovery_retry(job, reason, start_worker) do
    Logger.warning(
      "work_recovery_retry_scheduled job_id=#{job.id} kind=#{job.kind} " <>
        "error_code=#{recovery_error_code(reason)}"
    )

    case Task.Supervisor.start_child(OpenAgents.ProviderTaskSupervisor, fn ->
           retry_recovery(job.id, job.kind, start_worker, @recovery_retry_delays_ms)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, task_reason} ->
        Logger.error(
          "work_recovery_retry_start_failed job_id=#{job.id} kind=#{job.kind} " <>
            "error_code=#{recovery_error_code(task_reason)}"
        )

        {:ok, _job} = finish_job(job.id, "interrupted", error_code: "runtime_restarted")
        :ok
    end
  end

  defp retry_recovery(job_id, kind, start_worker, [delay_ms | remaining_delays]) do
    receive do
    after
      delay_ms -> :ok
    end

    case get_job(job_id) do
      %Job{status: status} when status in @active_statuses ->
        case start_worker.(worker_module(kind), job_id) do
          {:ok, _pid_or_ignore} ->
            Logger.info("work_recovery_resumed job_id=#{job_id} kind=#{kind}")
            :ok

          {:error, reason} when remaining_delays != [] ->
            Logger.warning(
              "work_recovery_retry job_id=#{job_id} kind=#{kind} " <>
                "error_code=#{recovery_error_code(reason)}"
            )

            retry_recovery(job_id, kind, start_worker, remaining_delays)

          {:error, reason} ->
            Logger.error(
              "work_recovery_exhausted job_id=#{job_id} kind=#{kind} " <>
                "error_code=#{recovery_error_code(reason)}"
            )

            {:ok, _job} =
              finish_job(job_id, "interrupted", error_code: "runtime_restarted")

            :ok
        end

      _terminal_or_missing ->
        :ok
    end
  end

  defp recovery_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp recovery_error_code({reason, _detail}) when is_atom(reason),
    do: Atom.to_string(reason)

  defp recovery_error_code(_reason), do: "worker_start_failed"

  defp worker_module("delegation"), do: OpenAgents.Work.DelegationServer
  defp worker_module("scv"), do: OpenAgents.Work.ScvServer

  defp worker_module("continual_learning"), do: OpenAgents.Work.ContinualLearningServer
  defp worker_module(_kind), do: OpenAgents.Work.JobServer

  @doc """
  Durably checkpoints the live ACP session id into the delegation job row
  (fenced by generation), so a plain restart — single node, no Ra — resumes the
  same agent session by id instead of orphaning it (#97). The Ra registry
  carries the same checkpoint cluster-wide on the fleet.
  """
  def checkpoint_delegation_session(job_id, generation, session_id)
      when is_binary(session_id) do
    Repo.transaction(fn ->
      job = Repo.one!(from(job in Job, where: job.id == ^job_id, lock: "FOR UPDATE"))

      if job.status == "running" and job.generation == generation do
        delegation = Map.put(job.delegation || %{}, "resume_session_id", session_id)

        {:ok, _job} =
          job
          |> Ecto.Changeset.change(delegation: delegation)
          |> Repo.update()

        :ok
      else
        # A newer owner claimed the job (or it went terminal): this writer is
        # superseded — its checkpoint must lose.
        :fenced
      end
    end)
  end

  # A restart that interrupts in-flight work is a durable, queryable incident, so
  # "why did my delegation stop?" is answerable from evidence rather than a
  # confusing report. Classified degraded (a restart, not an anomaly), so it is
  # recorded and — only on recurrence — surfaced, never auto-escalated.
  defp record_interruption_incident(%Job{} = job) do
    owner_user_id =
      case get_job_owner(job) do
        %{user_id: user_id} -> user_id
        _absent -> nil
      end

    OpenAgents.Incidents.report(%{
      conversation_id: job.conversation_id,
      owner_user_id: owner_user_id,
      owner_visitor_id: job.owner_visitor_id,
      surface: if(job.kind == "delegation", do: "delegation", else: "job"),
      origin: "work_recovery",
      correlation_ref: job.id,
      code: "runtime_restarted",
      summary: "#{job.kind} interrupted by a server restart",
      context: %{"kind" => job.kind, "goal" => job.goal}
    })
  rescue
    _error -> :ok
  end

  defp get_job_owner(%Job{owner_visitor_id: owner_visitor_id}) when is_binary(owner_visitor_id),
    do: Repo.get(Visitor, owner_visitor_id)

  defp get_job_owner(_job), do: nil

  defp interruption_status("interrupted"), do: "interrupted"
  defp interruption_status("budget_exhausted"), do: "cancelled"
  defp interruption_status("cancelled"), do: "cancelled"
  defp interruption_status(_status), do: "failed"

  defp terminate_active_steps(repo, job_id, step_status, error_code, now) do
    steps =
      repo.all(
        from(step in JobStep,
          where: step.work_job_id == ^job_id and step.status in ["requested", "running"],
          lock: "FOR UPDATE"
        )
      )

    Enum.reduce_while(steps, {:ok, 0}, fn step, {:ok, count} ->
      outcome_error = %{
        "code" => normalize_error_code(error_code) || "work_job_ended",
        "message" => "The tool call ended with the containing work job."
      }

      attributes = %{
        status: step_status,
        outcome_digest:
          Canonical.digest!(%{
            "schema" => "sarah.tool_outcome.v1",
            "call_id" => step.provider_call_id,
            "status" => step_status,
            "error" => outcome_error
          }),
        error: outcome_error,
        usage: %{"invocations" => 1},
        executor_id: "sarah.host",
        executor_disclosure: "Sarah host lifecycle",
        target_receipt_refs: [],
        attribution_refs: [],
        completed_at: now
      }

      case repo.update(JobStep.terminal_changeset(step, attributes)) do
        {:ok, _step} -> {:cont, {:ok, count + 1}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  # Every terminal path stores a non-empty report: the accumulated model text
  # when there is any, otherwise an honest host summary of the committed step
  # evidence (RLM partial-answer discipline).
  defp compose_report(repo, locked_job, status) do
    accumulated = String.trim(locked_job.report || "")

    report =
      if accumulated == "" do
        fallback_report(repo, locked_job, status)
      else
        accumulated
      end

    truncate_utf8(report, Job.maximum_report_bytes())
  end

  # A delegation job has no LLM steps of its own — its work is on the paired
  # computer — so the deep-work step summary is wrong and misleading for it. Give
  # it an honest, kind-aware report that names the interruption and how to resume.
  defp fallback_report(_repo, %Job{kind: "delegation"} = locked_job, status) do
    authority = locked_job.authority_snapshot || %{}
    agent = authority["agent_id"] || "the agent"
    computer = authority["machine_name"] || "the computer"

    case status do
      "interrupted" ->
        "Delegation to #{agent} on #{computer} was interrupted by a server restart " <>
          "before it finished. It did not complete; start it again to continue. " <>
          "Goal: #{locked_job.goal}"

      "cancelled" ->
        "Delegation to #{agent} on #{computer} was cancelled. Goal: #{locked_job.goal}"

      _other ->
        "Delegation to #{agent} on #{computer} ended #{status} before reporting a result. " <>
          "Goal: #{locked_job.goal}"
    end
  end

  # An SCV deployment has no LLM steps of its own either — its work happened in
  # an OpenCode process on our capacity — so it gets a report that names the
  # repository and the outcome rather than a step summary that would be empty.
  defp fallback_report(_repo, %Job{kind: "scv"} = locked_job, status) do
    authority = locked_job.authority_snapshot || %{}
    path = authority["repository_path"] || "the repository"

    case status do
      "interrupted" ->
        "SCV deployment on #{path} was interrupted by a server restart before it " <>
          "finished. An SCV has no session to resume; deploy it again to continue. " <>
          "Objective: #{locked_job.goal}"

      "cancelled" ->
        "SCV deployment on #{path} was cancelled. Objective: #{locked_job.goal}"

      _other ->
        "SCV deployment on #{path} ended #{status} before reporting a result. " <>
          "Objective: #{locked_job.goal}"
    end
  end

  # A continual-learning run reports rounds and checkpoints, not tool calls, and
  # an interruption is resumable from its last committed checkpoint rather than
  # something to start over.
  defp fallback_report(_repo, %Job{kind: "continual_learning"} = locked_job, status) do
    delegation = locked_job.delegation || %{}
    reference = delegation["continual_learning_job_id"] || locked_job.id

    case status do
      "interrupted" ->
        "Continual-learning job #{reference} was interrupted by a server restart. " <>
          "Its committed checkpoints survive; resume it to continue from the last " <>
          "one. Objective: #{locked_job.goal}"

      "cancelled" ->
        "Continual-learning job #{reference} was cancelled. Objective: #{locked_job.goal}"

      _other ->
        "Continual-learning job #{reference} ended #{status}. " <>
          "Objective: #{locked_job.goal}"
    end
  end

  defp fallback_report(repo, locked_job, status) do
    steps =
      repo.all(
        from(step in JobStep,
          where: step.work_job_id == ^locked_job.id,
          order_by: [asc: step.sequence],
          select: {step.tool_name, step.status}
        )
      )

    step_summary =
      if steps == [] do
        "no tool calls had completed"
      else
        counts =
          steps
          |> Enum.map(fn {name, step_status} -> "#{name}:#{step_status}" end)
          |> Enum.join(", ")

        "durable step evidence: #{counts}"
      end

    "Deep work job ended #{status} before producing a narrative report; " <>
      "#{step_summary}. Goal: #{locked_job.goal}"
  end

  defp deliver_live_voice_report(%Job{} = job, %Message{} = message) do
    conversation = %Conversation{id: job.conversation_id}

    case OpenAgents.Voice.active_session(conversation) do
      nil ->
        :ok

      session ->
        # The existing typed-message injection path adds the bounded report to
        # the live provider conversation so voice Sarah can speak to it.
        OpenAgents.VoiceSessions.inject_typed_message(session, message)
    end
  rescue
    # A live-voice projection failure must never rewrite or fail the durable
    # terminal job state committed above.
    _exception -> :ok
  end

  defp validate_raw_arguments(arguments)
       when is_binary(arguments) and byte_size(arguments) <= 262_144,
       do: :ok

  defp validate_raw_arguments(_arguments), do: {:error, :invalid_tool_arguments}

  defp argument_digest(raw_arguments) do
    case Jason.decode(raw_arguments) do
      {:ok, decoded} ->
        Canonical.digest(decoded)

      {:error, _decode_error} ->
        Canonical.digest(%{"invalid_json_sha256" => Canonical.sha256(raw_arguments)})
    end
  end

  defp validate_outcome(step, outcome) do
    statuses = ~w(succeeded failed refused cancelled unavailable)

    cond do
      outcome["call_id"] != step.provider_call_id ->
        {:error, :tool_outcome_call_id_mismatch}

      get_in(outcome, ["module_ref", "tool_name"]) != step.tool_name ->
        {:error, :tool_outcome_name_mismatch}

      outcome["status"] not in statuses ->
        {:error, :invalid_tool_outcome_status}

      not is_map(outcome["executor_ref"]) ->
        {:error, :invalid_tool_outcome_executor}

      not is_list(outcome["target_receipt_refs"]) or not is_list(outcome["attribution_refs"]) ->
        {:error, :invalid_tool_outcome_refs}

      true ->
        :ok
    end
  end

  defp normalize_error_code(nil), do: nil
  defp normalize_error_code(code) when is_atom(code), do: Atom.to_string(code)

  defp normalize_error_code(code) when is_binary(code) do
    if byte_size(code) <= 128, do: code, else: "work_job_failure"
  end

  defp normalize_error_code(_code), do: "work_job_failure"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp truncate_utf8(value, maximum) when byte_size(value) <= maximum, do: value

  defp truncate_utf8(value, maximum) do
    value
    |> String.codepoints()
    |> Enum.reduce_while({0, []}, fn codepoint, {bytes, acc} ->
      next = bytes + byte_size(codepoint)
      if next > maximum, do: {:halt, {bytes, acc}}, else: {:cont, {next, [codepoint | acc]}}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp broadcast_job(%Job{} = job) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      work_topic(job.conversation_id),
      {:work_job_updated, job}
    )
  end

  defp work_topic(conversation_id), do: "work_jobs:#{conversation_id}"
end
