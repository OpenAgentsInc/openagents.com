defmodule OpenAgents.Work.JobServer do
  @moduledoc """
  Temporary supervised worker for one durable deep-work job.

  Drives the same configured text provider as `OpenAgents.Turns.TurnServer`, over
  the same captured tool catalog snapshot and the same governed
  `OpenAgents.Tools.Runner`, but inside its own bounded loop: at most 32 tool
  calls and 32 continuations, a ten-minute wall clock, and a forced
  tool-free report request when a bound trips — so every terminal path
  ends with a durable, possibly partial, report instead of silent death.

  The job itself never carries the `work.delegate` authority and its provider
  request never advertises `deep_work`, so a job cannot recurse into another
  job (recursion depth stays at one).
  """

  # :transient — Horde relocates a running job to a survivor on node death; a
  # clean terminal finish (:normal) is not restarted. A relocated JobServer
  # adopts the running row and re-drives the deep-work loop (see init).
  use GenServer, restart: :transient

  alias OpenAgents.{Blueprint, Context.Composer, Machines, Modules.Lifecycle, ProfileMemory, Work}
  alias OpenAgents.Work.Coding
  alias OpenAgents.Providers.{ProviderEvent, Request, ToolOutput}
  alias OpenAgents.Tools.{ExecutionContext, Registry, Runner}

  @maximum_tool_calls 32
  @maximum_continuations 32
  @maximum_job_ms 600_000

  def start_link(job_id) do
    GenServer.start_link(__MODULE__, job_id, name: via(job_id))
  end

  @impl true
  def init(job_id) do
    job = Work.get_job!(job_id)
    owner = Work.get_job_owner!(job)

    case Lifecycle.capture(Registry.current!()) do
      {:ok, tool_snapshot} -> initialize(job, owner, tool_snapshot)
      {:error, reason} -> stop_before_start(job, reason)
    end
  end

  defp initialize(job, owner, tool_snapshot) do
    provider = Application.fetch_env!(:openagents, :provider)
    tools_enabled = :tool_calls in provider.capabilities()

    definitions =
      if tools_enabled,
        do: job_tool_definitions(tool_snapshot, goal_prompt(job), owner, job),
        else: []

    capabilities = Enum.map(definitions, &%{id: &1.name, description: &1.description})

    profile_memory_snapshot_ref =
      case ProfileMemory.capture_snapshot(owner) do
        {:ok, snapshot} -> snapshot.ref
        {:error, _reason} -> nil
      end

    # A coding job composes with the admitted coding-lieutenant role; every
    # other kind keeps the default selection.
    role_options =
      case Coding.coding?(job) && Coding.role_selection() do
        %OpenAgents.Roles.Selection{} = selection -> [role_selection: selection]
        _not_coding -> []
      end

    with {:ok, blueprint} <- Blueprint.current_projection(),
         context <-
           Composer.compose!([capabilities: capabilities, blueprint: blueprint] ++ role_options),
         model_id <- Application.fetch_env!(:openagents, :openai_model),
         request <- %Request{
           model_id: model_id,
           instructions: context.instructions,
           input: [%{role: "user", content: goal_prompt(job)}],
           tool_definitions: definitions
         },
         {:ok, claimed_job} <-
           Work.claim_for_run(job.id, %{
             model_id: model_id,
             instruction_digest: context.instruction_digest,
             tool_catalog_digest: tool_snapshot.digest,
             memory_snapshot_ref: Work.capture_recall_ref(job.conversation_id, job.id)
           }),
         {:ok, running_job} <- Coding.on_start(claimed_job) do
      timeout_reference = Process.send_after(self(), :job_timeout, @maximum_job_ms)

      {:ok,
       %{
         job: running_job,
         owner: owner,
         provider: provider,
         tools_enabled: tools_enabled,
         tool_snapshot: tool_snapshot,
         base_request: request,
         profile_memory_snapshot_ref: profile_memory_snapshot_ref,
         task: start_provider_task(provider, request),
         phase: :provider,
         response_id: nil,
         current_usage: nil,
         usage: nil,
         pending_tool: nil,
         tool_call_count: 0,
         continuation_count: 0,
         report_phase?: false,
         limit_code: nil,
         terminal_event: nil,
         cancellation: :atomics.new(1, []),
         timeout_reference: timeout_reference
       }}
    else
      {:error, reason} -> stop_before_start(job, reason)
    end
  end

  defp stop_before_start(job, reason) do
    _failure = Work.finish_job(job.id, "failed", error_code: error_code(reason))
    {:stop, :normal}
  end

  # The goal is the whole delegated program: the model plans, calls governed
  # tools serially, and must finish with one bounded report.
  defp goal_prompt(%{goal: goal, context_hint: nil}), do: goal

  defp goal_prompt(%{goal: goal, context_hint: context_hint}),
    do: goal <> "\n\nContext: " <> context_hint

  # The job's catalog is the captured text catalog minus tools the job cannot
  # honestly use: `deep_work` itself (recursion depth 1) and any tool whose
  # required authority is outside the job's authority set.
  defp job_tool_definitions(tool_snapshot, intent, owner, job) do
    authorities = execution_authorities(job)

    tool_snapshot
    |> Registry.prompt_definitions(intent,
      machine_paired?: Machines.active_machine?(owner.user_id)
    )
    |> Enum.filter(fn definition ->
      case Map.fetch(tool_snapshot.tools, definition.name) do
        {:ok, tool} ->
          tool.name != "deep_work" and MapSet.member?(authorities, tool.required_authority)

        :error ->
          false
      end
    end)
  end

  @impl true
  def handle_cast(:cancel, state) do
    stop_terminal(state, "cancelled", :cancelled)
  end

  @impl true
  def handle_info(:job_timeout, state) do
    :atomics.put(state.cancellation, 1, 1)
    stop_terminal(state, "budget_exhausted", :wall_clock_exceeded)
  end

  def handle_info({:provider_event, event}, %{phase: :provider} = state),
    do: handle_provider_event(event, state)

  def handle_info({:provider_event, _event}, state),
    do: stop_terminal(state, "failed", :invalid_provider_event)

  def handle_info({reference, result}, %{task: %{ref: reference}, phase: :provider} = state) do
    Process.demonitor(reference, [:flush])
    finalize_provider_result(result, state)
  end

  def handle_info({reference, result}, %{task: %{ref: reference}, phase: :tool} = state) do
    Process.demonitor(reference, [:flush])
    finalize_tool_result(result, state)
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task: %{ref: reference}} = state) do
    stop_terminal(state, "failed", :provider_task_exited)
  end

  defp handle_provider_event(_event, %{terminal_event: terminal_event} = state)
       when not is_nil(terminal_event),
       do: stop_terminal(state, "failed", :invalid_provider_event)

  defp handle_provider_event({:response_started, response_id}, state)
       when is_binary(response_id) do
    {:noreply, %{state | response_id: response_id}}
  end

  defp handle_provider_event({:text_delta, delta}, state) when is_binary(delta) do
    case Work.append_report_delta(state.job, delta) do
      {:ok, job} -> {:noreply, %{state | job: job}}
      {:error, reason} -> stop_terminal(state, "failed", reason)
    end
  end

  defp handle_provider_event({:usage, usage}, state) when is_map(usage) do
    {:noreply, %{state | current_usage: usage}}
  end

  defp handle_provider_event({:tool_call, %ProviderEvent.ToolCall{} = call}, state) do
    cond do
      not state.tools_enabled ->
        stop_terminal(state, "failed", :unsupported_tool_call)

      is_nil(state.response_id) ->
        stop_terminal(state, "failed", :tool_call_before_response_start)

      not is_nil(state.pending_tool) ->
        stop_terminal(state, "failed", :parallel_tool_calls_not_supported)

      # The report request carries no tool definitions, so a compliant
      # provider can never reach these branches.
      state.report_phase? ->
        stop_terminal(state, "failed", :tool_call_after_report_request)

      state.tool_call_count >= @maximum_tool_calls * 2 ->
        stop_terminal(state, "failed", :tool_call_limit_reached)

      true ->
        persist_tool_request(call, state)
    end
  end

  defp handle_provider_event({:response_completed, response_id}, state)
       when is_binary(response_id) do
    if state.response_id == response_id,
      do: {:noreply, %{state | terminal_event: {:completed, response_id}}},
      else: stop_terminal(state, "failed", :invalid_provider_event)
  end

  defp handle_provider_event({:failed, reason}, state),
    do: {:noreply, %{state | terminal_event: {:failed, reason}}}

  defp handle_provider_event(:cancelled, state),
    do: {:noreply, %{state | terminal_event: {:failed, :provider_cancelled}}}

  defp handle_provider_event(_event, state),
    do: stop_terminal(state, "failed", :invalid_provider_event)

  defp persist_tool_request(call, state) do
    {module_id, version, artifact_digest} =
      case Map.fetch(state.tool_snapshot.tools, call.name) do
        {:ok, tool} ->
          artifact = Map.fetch!(state.tool_snapshot.modules, {tool.module_id, tool.version})
          {tool.module_id, tool.version, artifact.artifact_digest}

        :error ->
          {"sarah.host", 1, nil}
      end

    attributes = %{
      provider_call_id: call.call_id,
      provider_item_id: call.item_id,
      provider_response_id: state.response_id,
      tool_name: call.name,
      tool_version: version,
      module_id: module_id,
      module_artifact_digest: artifact_digest,
      catalog_digest: state.tool_snapshot.digest,
      raw_arguments: call.raw_arguments
    }

    case Work.request_job_step(state.job, attributes) do
      {:ok, step, _disposition} ->
        {:noreply,
         %{
           state
           | pending_tool: %{step: step, raw_arguments: call.raw_arguments},
             tool_call_count: state.tool_call_count + 1
         }}

      {:error, reason} ->
        stop_terminal(state, "failed", reason)
    end
  end

  defp finalize_provider_result(:ok, %{terminal_event: {:completed, _response_id}} = state) do
    updated_state = %{
      state
      | usage: merge_usage(state.usage, state.current_usage),
        current_usage: nil
    }

    case state.pending_tool do
      nil ->
        if state.report_phase? do
          # The forced tool-free report response finished: the job ends as an
          # explicit budget exhaustion carrying its partial report.
          stop_terminal(updated_state, "budget_exhausted", state.limit_code)
        else
          # The model stopped calling tools: its text is the report.
          stop_terminal(updated_state, "completed", nil)
        end

      pending_tool ->
        begin_tool_execution(pending_tool, updated_state)
    end
  end

  defp finalize_provider_result(:ok, %{terminal_event: {:failed, reason}} = state),
    do: stop_terminal(state, "failed", reason)

  defp finalize_provider_result(:ok, state),
    do: stop_terminal(state, "failed", :missing_terminal_event)

  defp finalize_provider_result({:error, reason}, state),
    do: stop_terminal(state, "failed", reason)

  defp finalize_provider_result(_other, state),
    do: stop_terminal(state, "failed", :unexpected_provider_result)

  defp begin_tool_execution(pending_tool, state) do
    with :ok <- check_execution_limits(state, pending_tool.step),
         :ok <- check_recursion(state, pending_tool.step),
         {:ok, running_step, :started} <- Work.start_job_step(pending_tool.step) do
      call = %{
        call_id: running_step.provider_call_id,
        name: running_step.tool_name,
        version: running_step.tool_version,
        raw_arguments: pending_tool.raw_arguments
      }

      scope_ref = "conversation:#{state.job.conversation_id}"

      execution_context = %ExecutionContext{
        scope: "browser_conversation",
        scope_ref: scope_ref,
        authorities: execution_authorities(state.job),
        # A durable job acts for the same signed-in owner in the same
        # conversation, so it carries the same machine-pairing approval receipts
        # a browser turn does. Without these, a computer delegation delegated
        # into a job (the durable path for work longer than one turn) would be
        # refused module_approval_required even though the machine is paired.
        approval_receipts:
          Machines.approval_receipts(state.owner.user_id, scope_ref) ++
            job_approval_receipts(state.job, scope_ref),
        surface: "text",
        job_ref: "work-job:#{state.job.id}",
        conversation_id: state.job.conversation_id,
        owner_visitor_id: state.owner.id,
        memory_snapshot_ref: state.job.memory_snapshot_ref,
        profile_memory_snapshot_ref: state.profile_memory_snapshot_ref,
        module_registry_snapshot: state.tool_snapshot
      }

      cancellation = state.cancellation
      snapshot = state.tool_snapshot

      task =
        Task.Supervisor.async_nolink(OpenAgents.ProviderTaskSupervisor, fn ->
          Runner.run(snapshot, call, execution_context,
            cancel?: fn -> :atomics.get(cancellation, 1) == 1 end
          )
        end)

      {:noreply,
       %{
         state
         | phase: :tool,
           task: task,
           pending_tool: %{pending_tool | step: running_step},
           terminal_event: nil
       }}
    else
      {:limit_reached, completed_step, code} ->
        begin_report_continuation(completed_step, code, state)

      {:recursion_refused, completed_step} ->
        # A refused recursion attempt is one durable typed outcome; the loop
        # continues with the same governed catalog rather than ending early.
        continue_with_step(completed_step, state, report_phase: false)

      {:error, reason} ->
        stop_terminal(state, "failed", reason)

      {:ok, _running_step, :already_running} ->
        stop_terminal(state, "failed", :duplicate_tool_execution_claim)
    end
  end

  defp check_execution_limits(state, step) do
    code =
      cond do
        state.tool_call_count > @maximum_tool_calls -> "tool_call_limit_reached"
        state.continuation_count >= @maximum_continuations -> "continuation_limit_reached"
        true -> nil
      end

    if is_nil(code) do
      :ok
    else
      case refuse_step(step, "failed", code, "The job reached a host execution limit.") do
        {:ok, completed_step} -> {:limit_reached, completed_step, code}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A job never delegates to another job: the definition is filtered out of
  # the request, and a call that arrives anyway is refused with a durable
  # typed outcome rather than executed.
  defp check_recursion(state, step) do
    if step.tool_name == "deep_work" and not state.report_phase? do
      case refuse_step(
             step,
             "refused",
             "work_recursion_refused",
             "A deep work job cannot start another deep work job."
           ) do
        {:ok, completed_step} -> {:recursion_refused, completed_step}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp refuse_step(step, status, code, message) do
    outcome = host_outcome(step, status, code, message)
    Work.complete_job_step(step, outcome)
  end

  # A host bound refuses the call and forces one final tool-free report
  # response, so the job still ends with partial findings (TURN-005 pattern).
  defp begin_report_continuation(completed_step, code, state) do
    continue_with_step(completed_step, %{state | limit_code: code}, report_phase: true)
  end

  defp finalize_tool_result({:ok, outcome}, state) do
    case Work.complete_job_step(state.pending_tool.step, outcome) do
      {:ok, completed_step} ->
        continue_with_step(completed_step, state, report_phase: state.report_phase?)

      {:error, reason} ->
        stop_terminal(state, "failed", reason)
    end
  end

  defp finalize_tool_result({:error, reason}, state),
    do: stop_terminal(state, "failed", reason)

  defp finalize_tool_result(_other, state),
    do: stop_terminal(state, "failed", :unexpected_tool_result)

  defp continue_with_step(completed_step, state, options) do
    report_phase? = Keyword.fetch!(options, :report_phase)

    case Work.step_continuation_output(completed_step) do
      {:ok, continuation} ->
        output =
          continuation["output"]
          |> Map.put("outcome_digest", continuation["outcome_digest"])

        request = %{
          state.base_request
          | input: [],
            previous_response_id: state.response_id,
            tool_outputs: [
              %ToolOutput{call_id: completed_step.provider_call_id, output: output}
            ],
            tool_definitions: if(report_phase?, do: [], else: state.base_request.tool_definitions)
        }

        {:noreply,
         %{
           state
           | phase: :provider,
             task: start_provider_task(state.provider, request),
             response_id: nil,
             current_usage: nil,
             pending_tool: nil,
             terminal_event: nil,
             report_phase?: report_phase?,
             continuation_count: state.continuation_count + 1
         }}

      {:error, reason} ->
        stop_terminal(state, "failed", reason)
    end
  end

  defp start_provider_task(provider, request) do
    server = self()

    Task.Supervisor.async_nolink(OpenAgents.ProviderTaskSupervisor, fn ->
      provider.stream(request, fn event -> send(server, {:provider_event, event}) end)
    end)
  end

  defp stop_terminal(state, status, reason) do
    :atomics.put(state.cancellation, 1, 1)
    cancel_task(state.task)
    _timer_result = Process.cancel_timer(state.timeout_reference)

    _terminal_result =
      Work.finish_job(state.job.id, status,
        error_code: if(is_nil(reason), do: nil, else: error_code(reason)),
        usage: merge_usage(state.usage, state.current_usage),
        tool_call_count: state.tool_call_count,
        continuation_count: state.continuation_count
      )

    if status == "failed", do: report_job_incident(state, reason)

    {:stop, :normal, state}
  end

  # A failed durable job is a durable incident too, so job failures are as
  # queryable as turn failures. Origin "job_server" is deliberately not
  # auto-fixed (OpenAgents.Incidents.Fixer only works user-facing turn failures), so
  # a failing fixer job can never spawn another fixer.
  defp report_job_incident(state, reason) do
    code = if is_nil(reason), do: "job_failed", else: error_code(reason)

    OpenAgents.Incidents.report(%{
      conversation_id: state.job.conversation_id,
      owner_user_id: state.owner.user_id,
      owner_visitor_id: state.job.owner_visitor_id,
      surface: "job",
      origin: "job_server",
      correlation_ref: state.job.id,
      code: code,
      summary: "Durable job failed: #{code}",
      context: %{
        "tool_call_count" => state.tool_call_count,
        "continuation_count" => state.continuation_count
      }
    })
  rescue
    _error -> :ok
  end

  defp cancel_task(nil), do: :ok

  defp cancel_task(task) do
    case Task.shutdown(task, 500) do
      nil -> Task.shutdown(task, :brutal_kill)
      _result -> :ok
    end
  end

  defp merge_usage(nil, nil), do: nil
  defp merge_usage(usage, nil), do: usage
  defp merge_usage(nil, usage), do: usage

  defp merge_usage(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value -> left_value + right_value end)
  end

  defp host_outcome(step, status, code, message) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "schema" => "sarah.tool_outcome.v1",
      "call_id" => step.provider_call_id,
      "module_ref" => %{
        "module_id" => step.module_id,
        "tool_name" => step.tool_name,
        "version" => step.tool_version,
        "artifact_digest" => step.module_artifact_digest
      },
      "executor_ref" => %{
        "id" => "sarah.host",
        "disclosure" => "Sarah host limits",
        "implementation_digest" => nil
      },
      "status" => status,
      "result" => nil,
      "error" => %{"code" => code, "message" => message},
      "target_receipt_refs" => [],
      "attribution_refs" => [],
      "started_at" => now,
      "completed_at" => now
    }
  end

  # The same read-oriented text authorities as a turn, minus `memory.write`
  # (a job has no current user message to satisfy MEMORY-005 consent) and
  # minus `work.delegate` (no recursion).
  defp execution_authorities(job) do
    base =
      MapSet.new([
        "computer.control",
        "conversation.read",
        "github.read",
        "memory.read",
        "module.discover"
      ])

    # A coding job additionally holds the repository authorities — the only
    # runtime that ever does (SELF-EDIT-001: turns and other kinds cannot
    # reach the repository tool family).
    if Coding.coding?(job),
      do: MapSet.union(base, MapSet.new(Coding.authorities())),
      else: base
  end

  # A coding job carries the approval receipts for its own repository
  # mutation modules (SELF-EDIT-001); other kinds carry none.
  defp job_approval_receipts(job, scope_ref) do
    if Coding.coding?(job),
      do: Coding.approval_receipts(scope_ref, "work-job:#{job.id}"),
      else: []
  end

  defp error_code(reason) when is_atom(reason), do: reason
  defp error_code(reason) when is_binary(reason), do: reason
  defp error_code({code, _detail}) when is_atom(code), do: code
  defp error_code(_reason), do: :work_job_failure

  defp via(job_id), do: {:via, Horde.Registry, {OpenAgents.HordeRegistry, {:work_job, job_id}}}
end
