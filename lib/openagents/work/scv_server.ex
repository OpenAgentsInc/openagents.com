defmodule OpenAgents.Work.ScvServer do
  @moduledoc """
  Supervised worker for one durable SCV deployment (SCV-001).

  Like `OpenAgents.Work.DelegationServer`, and unlike `OpenAgents.Work.JobServer`,
  this drives no model loop of its own: it runs one bounded
  `OpenAgents.SCV.run/1` to completion in its own process, so the turn that
  requested it returns immediately and the SCV works in the background. The
  difference from a delegation is where the work lands — a delegation ends on
  hardware the person owns, an SCV deployment ends on ours.

  Everything durable is the ordinary work-job machinery: the row, the seven
  statuses, the Horde singleton, the generation fence, the recovery sweep, and
  the bounded report posted back into the conversation. The run itself is
  bounded three ways at once — a wall clock the executor enforces and this
  server independently backstops, an output ceiling, and an objective cap
  fixed at admission.

  An interrupted SCV is NOT resumed. A coding agent's process died with its
  node; there is no session to re-attach, so recovery finishes the job
  honestly and the operator starts a new one.
  """

  # :transient — a crash on the same node is retried, and Horde relocates the
  # singleton to a survivor when its node dies. A clean finish is not restarted.
  use GenServer, restart: :transient

  alias OpenAgents.Incidents
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.SCV
  alias OpenAgents.SCV.Workspace
  alias OpenAgents.Work
  alias OpenAgents.Work.Scv

  # The report is a chat message, not a terminal window: the run's prose, the
  # tools it used, and how it ended. The event artifact stays on disk for an
  # operator, and the content-free projection stays on the status page.
  @maximum_report_output 4_000

  # The executor owns the wall clock; this is the backstop for a port that
  # somehow outlives it, so a stuck run cannot hold a slot forever.
  @deadline_grace_ms 60_000

  def start_link(job_id) do
    GenServer.start_link(__MODULE__, job_id, name: via(job_id))
  end

  @impl true
  def init(job_id) do
    # claim_for_run adopts a job left `running` by a now-dead node and refuses a
    # terminal one, so a relocated worker never re-runs finished work.
    case Work.claim_for_run(job_id) do
      {:ok, %{generation: generation} = claimed} when generation > 1 ->
        # A previous owner already spent capacity on this objective. An SCV has
        # no resumable session, so adopting it means finishing it honestly
        # rather than paying for the same work twice.
        _finished =
          Work.finish_job(claimed.id, "interrupted", error_code: "scv_run_interrupted")

        {:stop, :normal}

      {:ok, claimed} ->
        {:ok, %{job: claimed}, {:continue, :deploy}}

      {:error, _reason} ->
        {:stop, :normal}
    end
  end

  @impl true
  def handle_continue(:deploy, %{job: job}) do
    {:ok, job} = Scv.on_start(job)

    case prepare(job) do
      {:ok, prepared, workspace} ->
        deadline =
          Process.send_after(self(), :deadline, Scv.wall_clock_ms(prepared) + @deadline_grace_ms)

        {:noreply,
         %{
           job: prepared,
           workspace: workspace,
           deadline: deadline,
           task: start_run(prepared, workspace)
         }}

      {:error, reason} ->
        _report =
          Work.append_report_delta(job, "SCV deployment could not start: #{reason}.")

        _incident = report_incident(job, to_string(reason))
        _finished = Work.finish_job(job.id, "failed", error_code: to_string(reason))
        {:stop, :normal, %{job: job}}
    end
  end

  @impl true
  def handle_cast(:cancel, state) do
    _shutdown = Task.shutdown(state.task, :brutal_kill)
    _report = Work.append_report_delta(state.job, "SCV deployment cancelled by the operator.")
    _incident = report_incident(state.job, "cancelled")
    _finished = Work.finish_job(state.job.id, "cancelled", error_code: "cancelled")
    {:stop, :normal, state}
  end

  # The run returned: compose a bounded report, meter its usage, finish the job.
  @impl true
  def handle_info({reference, result}, %{task: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    _timer = cancel_deadline(state)
    {status, report, usage, code} = summarize(result, state.job)
    _report = Work.append_report_delta(state.job, report)
    if code, do: report_incident(state.job, code)
    _finished = Work.finish_job(state.job.id, status, error_code: code, usage: usage)
    {:stop, :normal, state}
  end

  def handle_info(:deadline, %{task: task} = state) do
    _shutdown = Task.shutdown(task, :brutal_kill)

    _report =
      Work.append_report_delta(
        state.job,
        "SCV deployment exceeded its admitted wall clock and was stopped."
      )

    _incident = report_incident(state.job, "scv_run_timeout")
    _finished = Work.finish_job(state.job.id, "failed", error_code: "scv_run_timeout")
    {:stop, :normal, state}
  end

  # The run task crashed: still finish the job honestly.
  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task: %{ref: reference}} = state) do
    _timer = cancel_deadline(state)
    _report = Work.append_report_delta(state.job, "The SCV worker stopped unexpectedly.")
    _incident = report_incident(state.job, "scv_worker_exited")
    _finished = Work.finish_job(state.job.id, "failed", error_code: "scv_worker_exited")
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── internal ───────────────────────────────────────────────────────────────

  # Clone the admitted repository at the admitted revision into a disposable
  # workspace and record its path on the row, so `Work.finish_job/3` can remove
  # it even if this process never runs again.
  defp prepare(job) do
    authority = job.authority_snapshot || %{}

    with %Repository{} = repository <- Repo.get(Repository, authority["repository_id"]),
         revision when is_binary(revision) <- authority["repository_revision"],
         {:ok, workspace} <- Workspace.prepare(repository, revision, job.id),
         {:ok, recorded} <- record_workspace(job, workspace) do
      {:ok, recorded, workspace}
    else
      {:error, reason} -> {:error, reason}
      _missing -> {:error, :scv_repository_unavailable}
    end
  end

  defp record_workspace(job, workspace) do
    job
    |> Ecto.Changeset.change(%{
      delegation: Map.put(job.delegation || %{}, "workspace_path", workspace)
    })
    |> Repo.update()
  end

  defp start_run(job, workspace) do
    objective = job.goal
    options = Scv.driver_options(job, event_sink(job))

    Task.Supervisor.async_nolink(OpenAgents.ProviderTaskSupervisor, fn ->
      SCV.run(workspace, objective,
        driver: :opencode,
        environment: :opencode_core,
        permission_profile: :read_only,
        run_id: job.id,
        driver_options: options
      )
    end)
  end

  # The executor already publishes each event as `[:openagents, :scv, :event]`
  # telemetry, which `OpenAgents.SCV.Activity` turns into the content-free
  # public projection on the status page. The sink is where an operator-facing
  # trace would attach; it stays a no-op so no event content is duplicated.
  defp event_sink(_job), do: fn _event -> :ok end

  defp cancel_deadline(%{deadline: reference}) when is_reference(reference),
    do: Process.cancel_timer(reference)

  defp cancel_deadline(_state), do: :ok

  defp summarize({:ok, %{status: "succeeded"} = result}, job),
    do: {"completed", report_text(result, job), usage(result), nil}

  defp summarize({:ok, %{status: "timeout"} = result}, job),
    do: {"failed", report_text(result, job), usage(result), "scv_run_timeout"}

  defp summarize({:ok, %{status: status} = result}, job),
    do: {"failed", report_text(result, job), usage(result), "scv_run_#{status}"}

  defp summarize({:error, reason}, job),
    do: {"failed", failure_text(reason, job), nil, error_code(reason)}

  defp summarize(_other, job),
    do: {"failed", failure_text(:unknown, job), nil, "scv_run_failed"}

  defp report_text(result, job) do
    authority = job.authority_snapshot || %{}
    path = authority["repository_path"] || "the repository"
    model = authority["model"] || "the admitted model"

    header =
      "SCV deployment on #{path} — #{human_status(result.status)}. " <>
        "Model: #{model}. Runtime: #{div(result.duration_ms, 1_000)}s."

    body =
      [tool_line(result), bound(prose(result)), truncation_line(result)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    if body == "", do: header, else: "#{header}\n\n#{body}"
  end

  defp failure_text(reason, job) do
    authority = job.authority_snapshot || %{}
    path = authority["repository_path"] || "the repository"
    "SCV deployment on #{path} could not run: #{error_code(reason)}."
  end

  defp prose(%{report: %{text: text}}) when is_binary(text), do: text
  defp prose(_result), do: ""

  defp truncation_line(%{report: %{truncated: true}}),
    do: "[the SCV's report was truncated at its admitted bound]"

  defp truncation_line(_result), do: nil

  defp tool_line(%{events: %{tool_calls: calls}}) when is_map(calls) and map_size(calls) > 0 do
    total = calls |> Map.values() |> Enum.sum()
    names = calls |> Map.keys() |> Enum.sort() |> Enum.join(", ")
    "The SCV ran #{total} tool #{pluralize(total)} (#{names})."
  end

  defp tool_line(_result), do: nil

  defp pluralize(1), do: "call"
  defp pluralize(_count), do: "calls"

  defp usage(%{events: %{usage: usage}}) when is_map(usage) do
    input = round_count(Map.get(usage, :input_tokens, 0))
    output = round_count(Map.get(usage, :output_tokens, 0))

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => input + output
    }
  end

  defp usage(_result), do: nil

  defp round_count(value) when is_integer(value) and value >= 0, do: value
  defp round_count(value) when is_float(value) and value >= 0, do: round(value)
  defp round_count(_value), do: 0

  defp bound(text) when is_binary(text) do
    if String.length(text) <= @maximum_report_output,
      do: text,
      else: String.slice(text, 0, @maximum_report_output) <> "\n\n[report truncated]"
  end

  defp human_status("succeeded"), do: "completed"
  defp human_status("timeout"), do: "timed out"
  defp human_status("failed"), do: "failed"
  defp human_status(other), do: "ended (#{other})"

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "scv_run_failed"

  # A completed run is not an incident. Every other terminal is recorded so
  # "why did that SCV fail?" reads a typed code rather than a guess.
  defp report_incident(job, code) do
    authority = job.authority_snapshot || %{}

    Incidents.report(%{
      conversation_id: job.conversation_id,
      owner_user_id: incident_owner_user_id(job),
      owner_visitor_id: job.owner_visitor_id,
      surface: "scv",
      origin: "scv_server",
      correlation_ref: job.id,
      code: code,
      summary: "SCV deployment ended: #{code}",
      context: %{
        "repository_path" => authority["repository_path"] || "",
        "repository_revision" => authority["repository_revision"] || "",
        "model" => authority["model"] || "",
        "driver" => authority["driver"] || ""
      }
    })
  rescue
    _error -> :ok
  end

  defp incident_owner_user_id(job) do
    case Work.get_job_owner!(job) do
      %{user_id: user_id} -> user_id
      _absent -> nil
    end
  end

  defp via(job_id), do: {:via, Horde.Registry, {OpenAgents.HordeRegistry, {:work_job, job_id}}}
end
