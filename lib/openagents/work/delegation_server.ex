defmodule OpenAgents.Work.DelegationServer do
  @moduledoc """
  Supervised worker for one durable computer delegation.

  Unlike `OpenAgents.Work.JobServer` (which drives an LLM loop), this runs a single
  `OpenAgents.Computer.request_agent` delegation to completion in its own process, so
  the turn that requested it returns immediately and several delegations run at
  once. The delegation still streams to the conversation's live rail
  (`OpenAgents.ComputerActivity`) exactly as a synchronous one did; when it finishes,
  a bounded report is persisted as the job's report and posted into the
  conversation. A runtime restart mid-delegation is RESUMED by
  `Work.recover_interrupted_jobs/0`: the restarted worker adopts the row
  through the generation fence and re-attaches the same ACP session via the
  durably checkpointed session id (job row + Ra).
  """

  # :transient — a crash on the same node is retried, and (critically) Horde
  # relocates a running delegation to a survivor when its node dies. A clean
  # finish (:normal exit) is not restarted.
  use GenServer, restart: :transient

  alias OpenAgents.{Computer, Incidents, Work}
  alias OpenAgents.Cluster.Sessions
  alias OpenAgents.Computer.AcpTranscript

  # A report is a chat message, not a terminal window. It carries what the
  # agent said and any tool call that failed; the tool-by-tool log stays in the
  # live delegation rail. The bound is characters of that composed body.
  @maximum_report_output 2_000
  @maximum_detail 500

  def start_link(job_id) do
    GenServer.start_link(__MODULE__, job_id, name: via(job_id))
  end

  @impl true
  def init(job_id) do
    # claim_for_run adopts a job left `running` by a now-dead node (Horde
    # handoff), and refuses a terminal one — so a relocated worker either
    # resumes the delegation or stops cleanly, never re-runs finished work.
    case Work.claim_for_run(job_id) do
      {:ok, running} ->
        # Publish cluster-wide ownership through Ra (no-op off the fleet). The
        # generation is the fence token; a relocated instance bumps it, fencing
        # any zombie holding the older one.
        {:ok, ra_gen} = Sessions.claim({:delegation, job_id}, :delegation)
        # On a handoff, a prior owner may have checkpointed the live ACP session
        # id in Ra — resume that session by id instead of starting a fresh one,
        # so no orphaned agent is left on the machine (M2 external re-attach).
        resume_id = adopt_resume_session_id(job_id)
        state = start_delegation(running, ra_gen, resume_id)
        {:ok, state, {:continue, :noop}}

      {:error, _reason} ->
        {:stop, :normal}
    end
  end

  @impl true
  def handle_continue(:noop, state), do: {:noreply, state}

  @impl true
  def handle_cast(:cancel, state) do
    _shutdown = Task.shutdown(state.task, :brutal_kill)
    _report = Work.append_report_delta(state.job, "Delegation cancelled by the owner.")
    _incident = report_incident(state.job, {:ok, %{"status" => "cancelled"}})
    _finished = Work.finish_job(state.job.id, "cancelled", error_code: "cancelled")
    _ra = ra_finish(state)
    {:stop, :normal, state}
  end

  # The delegation returned: compose a bounded report and finish the job. This
  # is the durable record of the outcome — the report also posts into the
  # conversation as an assistant message.
  @impl true
  def handle_info({reference, result}, %{task: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    {status, report} = summarize(result, state.job)
    _report = Work.append_report_delta(state.job, report)
    _incident = report_incident(state.job, result)
    _finished = Work.finish_job(state.job.id, status, [])
    _ra = ra_finish(state)
    {:stop, :normal, state}
  end

  # The delegation task crashed: still finish the job honestly.
  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task: %{ref: reference}} = state) do
    _report = Work.append_report_delta(state.job, "The delegation worker stopped unexpectedly.")
    _finished = Work.finish_job(state.job.id, "failed", error_code: "delegation_worker_exited")
    _ra = ra_finish(state)
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── internal ───────────────────────────────────────────────────────────────

  # Release cluster-wide ownership on a terminal path (no-op off the fleet).
  defp ra_finish(%{job: job} = state),
    do: Sessions.finish({:delegation, job.id}, Map.get(state, :ra_gen, :local))

  defp start_delegation(job, ra_gen, resume_id) do
    params = job.delegation || %{}
    authority = job.authority_snapshot || %{}
    timeout_ms = timeout_ms(job)

    payload =
      %{
        "agent_id" => authority["agent_id"],
        "prompt" => params["prompt"],
        "timeout_ms" => timeout_ms
      }
      |> put_optional("cwd", authority["cwd"])
      |> put_optional("resume_session_id", resume_id || params["resume_session_id"])
      |> attach_inference_grant(job)

    # Checkpoint the ACP session id the moment the controller reports it — in
    # Ra (cluster-wide, for node-loss handoff) AND in the durable job row
    # (generation-fenced), so a plain single-node restart also resumes the same
    # session by id at boot instead of orphaning the agent (#97). A superseded
    # zombie's write loses in both stores.
    on_session = fn session_id ->
      Sessions.checkpoint({:delegation, job.id}, ra_gen, %{acp_session_id: session_id})
      Work.checkpoint_delegation_session(job.id, job.generation, session_id)
    end

    task =
      Task.Supervisor.async_nolink(OpenAgents.ProviderTaskSupervisor, fn ->
        # On an adopt (resume_id set) the machine's controller is likely mid-
        # reconnect after the node loss that relocated us here — give it a
        # bounded window (node-death detection + LB failover + rejoin) to
        # re-register before declaring it offline. Fresh delegations keep the
        # immediate offline answer.
        await_ms = if resume_id, do: 90_000, else: 0

        Computer.request_agent(
          job.machine_id,
          payload,
          timeout_ms + 15_000,
          on_session: on_session,
          await_machine_ms: await_ms
        )
      end)

    %{job: job, task: task, ra_gen: ra_gen}
  end

  # The ACP session id a prior owner committed to Ra for this job (nil if none,
  # or off the fleet where the facade no-ops).
  defp adopt_resume_session_id(job_id) do
    case Sessions.lookup({:delegation, job_id}) do
      {:ok, %{checkpoint: %{acp_session_id: session_id}}} when is_binary(session_id) ->
        session_id

      _absent ->
        nil
    end
  end

  # First-party probe delegations get a fresh, delegation-scoped inference
  # grant minted here — on the wire only. The plaintext token is never written
  # to the durable job (job.delegation persists no credential); the controller
  # injects it into the probe process at spawn. Any other agent (which brings
  # its own credential) gets nothing. A mint failure degrades to a
  # grant-less delegation rather than blocking the work.
  defp attach_inference_grant(payload, %{authority_snapshot: %{"agent_id" => "probe"}} = job)
       when is_binary(job.machine_id) do
    case OpenAgents.Inference.mint(%{
           owner_visitor_id: job.owner_visitor_id,
           conversation_id: job.conversation_id,
           machine_id: job.machine_id
         }) do
      {:ok, _grant, token} ->
        payload
        |> Map.put("inference_grant", token)
        |> Map.put("inference_url", OpenAgents.Inference.proxy_url())

      {:error, _reason} ->
        payload
    end
  end

  defp attach_inference_grant(payload, _job), do: payload

  defp summarize({:ok, %{"status" => "completed"} = payload}, job) do
    {"completed", report_line(job, "completed", payload["output"], payload["detail"], payload)}
  end

  defp summarize({:ok, %{"status" => status} = payload}, job) do
    {"failed", report_line(job, status, payload["output"], payload["detail"], payload)}
  end

  defp summarize({:refused, reason, detail}, job) do
    {"failed", report_line(job, "refused", nil, "#{reason}: #{detail}", %{})}
  end

  defp summarize({:error, reason}, job) do
    {"failed", report_line(job, to_string(reason), nil, nil, %{})}
  end

  defp summarize(_other, job) do
    {"failed", report_line(job, "failed", nil, nil, %{})}
  end

  defp report_line(job, status, output, detail, payload) do
    authority = job.authority_snapshot || %{}
    agent = authority["agent_id"] || "agent"
    machine = authority["machine_name"] || "the machine"
    header = "Delegation to #{agent} on #{machine} — #{human_status(status)}."

    body =
      [
        session_line(payload),
        runtime_line(payload),
        detail_line(detail),
        write_refusal_line(output),
        output_block(output)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    if body == "", do: header, else: "#{header}\n\n#{body}"
  end

  defp session_line(%{"session_id" => session_id})
       when is_binary(session_id) and session_id != "",
       do: "Session: #{String.slice(session_id, 0, 128)}"

  defp session_line(_payload), do: nil

  defp runtime_line(payload) when is_map(payload) do
    parts =
      [
        runtime_part("Model", payload["model"], 128),
        runtime_part("Reasoning", payload["reasoning_effort"], 32),
        runtime_part("Mode", payload["mode"], 32)
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: Enum.join(parts, " · ")
  end

  defp runtime_line(_payload), do: nil

  defp runtime_part(label, value, maximum) when is_binary(value) and value != "",
    do: "#{label}: #{String.slice(value, 0, maximum)}"

  defp runtime_part(_label, _value, _maximum), do: nil

  defp write_refusal_line(output) when is_binary(output) do
    transcript = AcpTranscript.decode(output)

    if String.contains?(transcript, "User refused permission") do
      "Write tools were refused by the machine policy. A coding task cannot " <>
        "finish until Edit/Write is allowed at curated tier inside declared roots."
    end
  end

  defp write_refusal_line(_output), do: nil

  defp human_status("completed"), do: "completed"
  defp human_status("timeout"), do: "timed out"
  defp human_status("cancelled"), do: "cancelled"
  defp human_status("unavailable"), do: "unavailable"
  defp human_status("refused"), do: "refused"
  defp human_status(other), do: "ended (#{other})"

  # The detail is controller-reported text: bound it before it reaches a message.
  defp detail_line(detail) when is_binary(detail) and detail != "",
    do: String.slice(detail, 0, @maximum_detail)

  defp detail_line(_detail), do: nil

  # The conversation gets the agent's answer, not its keystrokes. Posting the
  # whole decoded transcript dumped hundreds of `Terminal: …` lines into the
  # chat the moment a long delegation ended. What survives here is the prose,
  # the tool calls that failed, and a line counting the rest, so the work is
  # named without being replayed.
  defp output_block(output) when is_binary(output) and output != "" do
    {summary, tool_count} = AcpTranscript.summarize(output)

    case Enum.reject([bound_report(summary), tool_count_line(tool_count)], &(&1 in [nil, ""])) do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp output_block(_output), do: nil

  defp tool_count_line(0), do: nil
  defp tool_count_line(1), do: "The agent ran 1 tool call on the machine."
  defp tool_count_line(count), do: "The agent ran #{count} tool calls on the machine."

  defp bound_report(summary) do
    if String.length(summary) <= @maximum_report_output do
      summary
    else
      String.slice(summary, 0, @maximum_report_output) <> "\n\n[report truncated]"
    end
  end

  defp timeout_ms(%{budget_snapshot: %{"wall_clock_ms" => value}})
       when is_integer(value) and value > 0,
       do: value

  defp timeout_ms(_job), do: 3_600_000

  defp put_optional(payload, _key, value) when value in [nil, ""], do: payload
  defp put_optional(payload, key, value), do: Map.put(payload, key, value)

  # Completed delegations are not incidents. Every other terminal is recorded
  # so "why did that fail?" can read a typed code instead of a stale turn death.
  # The code is the controller/ACP status, not the work-job status (timeouts
  # finish the job as `failed`).
  defp report_incident(job, result) do
    status = acp_status(result)
    if status == "completed", do: :ok, else: write_incident(job, result, status)
  end

  defp write_incident(job, result, status) do
    code = incident_code(status)
    payload = incident_payload(result)
    authority = job.authority_snapshot || %{}
    owner_user_id = incident_owner_user_id(job)

    Incidents.report(%{
      conversation_id: job.conversation_id,
      owner_user_id: owner_user_id,
      owner_visitor_id: job.owner_visitor_id,
      surface: "delegation",
      origin: "delegation_server",
      correlation_ref: job.id,
      code: code,
      summary: "Delegation #{human_status(status)}: #{code}",
      context: %{
        "cwd" => authority["cwd"] || "",
        "agent_id" => authority["agent_id"] || "",
        "machine_id" => job.machine_id || "",
        "duration_ms" => payload["duration_ms"] || 0,
        "truncated" => payload["truncated"] || false,
        "session_id" => payload["session_id"] || ""
      }
    })
  rescue
    _error -> :ok
  end

  defp acp_status({:ok, %{"status" => status}}) when is_binary(status), do: status
  defp acp_status({:refused, _reason, _detail}), do: "refused"
  defp acp_status({:error, reason}), do: to_string(reason)
  defp acp_status(_other), do: "failed"

  defp incident_code("timeout"), do: "delegation_timeout"
  defp incident_code("refused"), do: "delegation_refused"
  defp incident_code("cancelled"), do: "delegation_cancelled"
  defp incident_code("machine_offline"), do: "machine_offline"
  defp incident_code(_other), do: "delegation_failed"

  defp incident_payload({:ok, payload}) when is_map(payload), do: payload
  defp incident_payload(_result), do: %{}

  defp incident_owner_user_id(job) do
    case Work.get_job_owner!(job) do
      %{user_id: user_id} -> user_id
      _absent -> nil
    end
  end

  defp via(job_id), do: {:via, Horde.Registry, {OpenAgents.HordeRegistry, {:work_job, job_id}}}
end
