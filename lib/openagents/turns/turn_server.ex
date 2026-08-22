defmodule OpenAgents.Turns.TurnServer do
  @moduledoc false

  use GenServer, restart: :temporary

  alias OpenAgents.{
    Blueprint,
    Context.Composer,
    Conversations,
    ExperienceMemory,
    Machines,
    Modules.Lifecycle,
    Modules.Router,
    Modules.RoutingReceipts,
    Preferences,
    ProfileMemory,
    ProgramLifecycle,
    ShadowPrograms
  }

  alias OpenAgents.Providers.{ProviderEvent, Request, ToolOutput}
  alias OpenAgents.Tools.{ConversationExecutionContext, Registry, Runner}

  @maximum_tool_calls 16
  @maximum_continuations 16
  @maximum_turn_ms 600_000
  @reason_code_max 64
  @reason_inspect_max 200

  def start_link(turn_id) do
    GenServer.start_link(__MODULE__, turn_id, name: via(turn_id))
  end

  @impl true
  def init(turn_id) do
    turn = Conversations.get_turn!(turn_id)
    owner = Conversations.get_turn_owner!(turn)

    case ProfileMemory.capture_snapshot(owner) do
      {:ok, profile_memory_snapshot} ->
        case Preferences.capture_snapshot(owner) do
          {:ok, preference_snapshot} ->
            initialize(turn, owner, profile_memory_snapshot, preference_snapshot)

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp initialize(turn, owner, profile_memory_snapshot, preference_snapshot) do
    case Lifecycle.capture(Registry.current!()) do
      {:ok, tool_snapshot} ->
        initialize_with_registry(
          turn,
          owner,
          profile_memory_snapshot,
          preference_snapshot,
          tool_snapshot
        )

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp initialize_with_registry(
         turn,
         owner,
         profile_memory_snapshot,
         preference_snapshot,
         tool_snapshot
       ) do
    messages = Conversations.provider_messages(turn.conversation_id)
    provider = Application.fetch_env!(:openagents, :provider)
    provider_capabilities = provider.capabilities()
    tools_enabled = :tool_calls in provider_capabilities

    capabilities =
      if tools_enabled, do: Registry.prompt_capability_descriptors(tool_snapshot), else: []

    program_snapshot = ProgramLifecycle.capture("sarah.memory.intent.v1")

    with {:ok, blueprint} <- Blueprint.current_projection(),
         {:ok, preference_projection} <-
           Preferences.project_active(owner, preference_snapshot, current_user_text(messages)),
         {:ok, experience_capture} <-
           ExperienceMemory.capture_for_turn(
             owner,
             turn,
             current_user_text(messages)
           ),
         context <-
           Composer.compose!(
             capabilities: capabilities,
             blueprint: blueprint,
             preferences: preference_projection.applied,
             experiences: experience_capture.projections
           ),
         model_id <- Application.fetch_env!(:openagents, :openai_model),
         request <- %Request{
           model_id: model_id,
           instructions: context.instructions,
           input: messages,
           tool_definitions:
             if(tools_enabled,
               do:
                 Registry.prompt_definitions(
                   tool_snapshot,
                   current_user_text(messages),
                   machine_paired?: Machines.active_machine?(owner.user_id)
                 ),
               else: []
             )
         },
         {:ok, records} <-
           Conversations.begin_inference(turn, context, request, provider.id(),
             tool_catalog_digest: tool_snapshot.digest,
             program_snapshot: program_snapshot,
             profile_memory_snapshot_ref: profile_memory_snapshot.ref,
             preference_snapshot_ref: preference_snapshot.ref,
             preference_usage: preference_projection.usage,
             experience_bank_ref: experience_capture.ref,
             experience_usage: experience_capture.usage
           ) do
      _shadow_start_result =
        ShadowPrograms.maybe_start(
          records.receipt.id,
          current_user_text(messages),
          program_snapshot
        )

      cancellation = :atomics.new(1, [])
      timeout_reference = Process.send_after(self(), :turn_timeout, @maximum_turn_ms)

      {:ok,
       %{
         turn: records.turn,
         receipt: records.receipt,
         task: start_provider_task(provider, request),
         phase: :provider,
         provider: provider,
         tools_enabled: tools_enabled,
         base_request: request,
         response_id: nil,
         current_usage: nil,
         usage: nil,
         tool_snapshot: tool_snapshot,
         routing_policy: ConversationExecutionContext.routing_policy(owner.user_id),
         program_snapshot: program_snapshot,
         pending_tool: nil,
         tool_call_count: 0,
         continuation_count: 0,
         terminal_event: nil,
         cancellation: cancellation,
         owner: owner,
         profile_memory_snapshot: profile_memory_snapshot,
         preference_snapshot: preference_snapshot,
         timeout_reference: timeout_reference
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp current_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "user", content: content} when is_binary(content) -> content
      _message -> nil
    end)
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    :atomics.put(state.cancellation, 1, 1)
    cancel_task(state.task)
    _timer_result = Process.cancel_timer(state.timeout_reference)
    result = Conversations.cancel_turn(state.turn, total_usage(state))
    {:stop, :normal, result, state}
  end

  @impl true
  def handle_info(:turn_timeout, state) do
    :atomics.put(state.cancellation, 1, 1)
    stop_failed(state, :turn_timeout)
  end

  def handle_info({:provider_event, event}, %{phase: :provider} = state),
    do: handle_provider_event(event, state)

  def handle_info({:provider_event, _event}, state),
    do: stop_failed(state, :invalid_provider_event)

  def handle_info({reference, result}, %{task: %{ref: reference}, phase: :provider} = state) do
    Process.demonitor(reference, [:flush])
    finalize_provider_result(result, state)
  end

  def handle_info({reference, result}, %{task: %{ref: reference}, phase: :tool} = state) do
    Process.demonitor(reference, [:flush])
    finalize_tool_result(result, state)
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, %{task: %{ref: reference}} = state) do
    stop_failed(state, normalize_task_exit(reason))
  end

  defp handle_provider_event(_event, %{terminal_event: terminal_event} = state)
       when not is_nil(terminal_event),
       do: stop_failed(state, :invalid_provider_event)

  defp handle_provider_event({:response_started, response_id}, state)
       when is_binary(response_id) do
    case Conversations.record_provider_response_started(state.receipt, response_id) do
      {:ok, _step} -> {:noreply, %{state | response_id: response_id}}
      {:error, reason} -> stop_failed(state, reason)
    end
  end

  defp handle_provider_event({:text_delta, delta}, state) when is_binary(delta) do
    case Conversations.append_assistant_delta(state.turn, delta) do
      {:ok, _message} -> {:noreply, state}
      {:error, reason} -> stop_failed(state, reason)
    end
  end

  defp handle_provider_event({:usage, usage}, state) when is_map(usage) do
    if valid_usage?(usage),
      do: {:noreply, %{state | current_usage: usage}},
      else: stop_failed(state, :invalid_provider_event)
  end

  defp handle_provider_event({:tool_call, %ProviderEvent.ToolCall{} = call}, state) do
    cond do
      not state.tools_enabled ->
        stop_failed(state, :unsupported_tool_call)

      is_nil(state.response_id) ->
        stop_failed(state, :tool_call_before_response_start)

      not is_nil(state.pending_tool) ->
        stop_failed(state, :parallel_tool_calls_not_supported)

      # Runaway backstop only: the limit report below removes tool definitions,
      # so a compliant provider can never reach this branch.
      state.tool_call_count >= @maximum_tool_calls * 2 ->
        stop_failed(state, :tool_call_limit_reached)

      true ->
        persist_tool_request(call, state)
    end
  end

  defp handle_provider_event({:response_completed, response_id}, state)
       when is_binary(response_id) do
    if state.response_id == response_id,
      do: {:noreply, %{state | terminal_event: {:completed, response_id}}},
      else: stop_failed(state, :invalid_provider_event)
  end

  defp handle_provider_event({:failed, reason}, state),
    do: {:noreply, %{state | terminal_event: {:failed, reason}}}

  defp handle_provider_event(:cancelled, state),
    do: {:noreply, %{state | terminal_event: :cancelled}}

  defp handle_provider_event(_event, state), do: stop_failed(state, :invalid_provider_event)

  defp persist_tool_request(call, state) do
    {module_id, version, artifact_digest, implementation_digest, tool} =
      case Map.fetch(state.tool_snapshot.tools, call.name) do
        {:ok, tool} ->
          artifact = Map.fetch!(state.tool_snapshot.modules, {tool.module_id, tool.version})

          {tool.module_id, tool.version, artifact.artifact_digest, artifact.implementation_digest,
           tool}

        :error ->
          {"sarah.host", 1, nil, nil, nil}
      end

    attribution_policy =
      if tool, do: tool.executor.attribution_policy, else: host_attribution_policy()

    attributes = %{
      provider_call_id: call.call_id,
      provider_item_id: call.item_id,
      provider_response_id: state.response_id,
      tool_name: call.name,
      tool_version: version,
      module_id: module_id,
      module_artifact_digest: artifact_digest,
      executor_implementation_digest: implementation_digest,
      side_effect_class: if(tool, do: Atom.to_string(tool.side_effect), else: "read_only"),
      attribution_policy_id: attribution_policy["id"],
      attribution_policy_version: attribution_policy["version"],
      attribution_policy_digest: attribution_policy["digest"],
      cost_units: if(tool, do: tool.executor.cost_units, else: 0),
      raw_arguments: call.raw_arguments
    }

    with {:ok, routing_decision} <- route_tool_call(tool, state),
         {:ok, routing_receipt} <-
           RoutingReceipts.persist(state.receipt.id, call.call_id, routing_decision),
         {:ok, step, _disposition} <-
           Conversations.request_tool_step(
             state.turn,
             state.receipt,
             Map.put(attributes, :routing_receipt_id, routing_receipt.id)
           ) do
      {:noreply,
       %{
         state
         | pending_tool: %{
             step: step,
             raw_arguments: call.raw_arguments,
             routing_decision: routing_decision,
             routing_receipt_id: routing_receipt.id
           },
           tool_call_count: state.tool_call_count + 1
       }}
    else
      {:error, reason} ->
        stop_failed(state, reason)
    end
  end

  defp route_tool_call(nil, state) do
    Router.route(state.tool_snapshot, state.routing_policy, %{
      intent_digest: state.receipt.input_digest,
      required_capability: "unknown",
      required_side_effect: "read_only",
      surface: "text",
      data_scope: "browser_conversation",
      authorities: ConversationExecutionContext.authorities(),
      exact_proposal: true
    })
  end

  defp route_tool_call(tool, state) do
    artifact = Map.fetch!(state.tool_snapshot.modules, {tool.module_id, tool.version})

    proposal = %{
      "module_id" => artifact.module_id,
      "version" => artifact.version,
      "artifact_digest" => artifact.artifact_digest,
      "registry_digest" => state.tool_snapshot.digest
    }

    Router.route(state.tool_snapshot, state.routing_policy, %{
      intent_digest: state.receipt.input_digest,
      required_capability: tool.required_authority,
      required_side_effect: Atom.to_string(tool.side_effect),
      surface: "text",
      data_scope: tool.required_scope,
      authorities: ConversationExecutionContext.authorities(),
      proposal: proposal,
      exact_proposal: true
    })
  end

  defp finalize_provider_result(:ok, %{terminal_event: {:completed, response_id}} = state) do
    provider_usage = state.current_usage

    updated_state = %{
      state
      | usage: merge_usage(state.usage, provider_usage),
        current_usage: nil
    }

    case state.pending_tool do
      nil ->
        finalize_text_response(response_id, updated_state)

      pending_tool ->
        begin_tool_execution(response_id, provider_usage, pending_tool, updated_state)
    end
  end

  defp finalize_provider_result(:ok, %{terminal_event: {:failed, reason}} = state),
    do: stop_failed(state, reason)

  defp finalize_provider_result(:ok, %{terminal_event: :cancelled} = state) do
    _cancel_result = Conversations.cancel_turn(state.turn, total_usage(state))
    {:stop, :normal, state}
  end

  defp finalize_provider_result(:ok, state), do: stop_failed(state, :missing_terminal_event)
  defp finalize_provider_result({:error, reason}, state), do: stop_failed(state, reason)

  defp finalize_provider_result(other, state),
    do: stop_failed(state, {:unexpected_provider_result, other})

  defp finalize_text_response(response_id, state) do
    case Conversations.complete_turn(state.turn, response_id, state.usage) do
      {:ok, _turn} ->
        _timer_result = Process.cancel_timer(state.timeout_reference)
        {:stop, :normal, state}

      {:error, reason} ->
        stop_failed(state, reason)
    end
  end

  defp begin_tool_execution(response_id, provider_usage, pending_tool, state) do
    with {:ok, _provider_step} <-
           Conversations.record_provider_step_completion(
             state.receipt,
             response_id,
             provider_usage
           ),
         :ok <- check_execution_limits(state, pending_tool.step),
         {:ok, running_step, :started} <- Conversations.start_tool_step(pending_tool.step) do
      call = %{
        call_id: running_step.provider_call_id,
        name: running_step.tool_name,
        version: running_step.tool_version,
        raw_arguments: pending_tool.raw_arguments
      }

      execution_context =
        ConversationExecutionContext.build(%{
          surface: "text",
          conversation_id: state.turn.conversation_id,
          current_user_message_id: state.turn.user_message_id,
          owner_visitor_id: state.owner.id,
          owner_user_id: state.owner.user_id,
          memory_snapshot_ref: state.receipt.memory_snapshot_ref,
          profile_memory_snapshot_ref: state.profile_memory_snapshot.ref,
          module_registry_snapshot: state.tool_snapshot
        })

      cancellation = state.cancellation
      snapshot = state.tool_snapshot
      routing_decision = pending_tool.routing_decision
      routing_policy = state.routing_policy

      routing_context = %{
        intent_digest: state.receipt.input_digest,
        required_capability: routing_decision.required_capability,
        required_side_effect: routing_decision.required_side_effect,
        surface: routing_decision.surface,
        data_scope: execution_context.scope,
        authorities: execution_context.authorities
      }

      task =
        Task.Supervisor.async_nolink(OpenAgents.ProviderTaskSupervisor, fn ->
          case Router.revalidate(routing_decision, snapshot, routing_policy, routing_context) do
            {:ok, _artifact} ->
              Runner.run(snapshot, call, execution_context,
                cancel?: fn -> :atomics.get(cancellation, 1) == 1 end
              )

            {:error, reason} ->
              {:ok, routing_failure_outcome(running_step, reason)}
          end
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
      {:limit_reached, completed_step} ->
        begin_limit_report(completed_step, state)

      {:error, reason} ->
        stop_failed(state, reason)

      {:ok, _running_step, :already_running} ->
        stop_failed(state, :duplicate_tool_execution_claim)
    end
  end

  # A host bound refuses the call and forces one final tool-free report
  # response, so the person gets partial findings instead of a failed turn.
  defp begin_limit_report(completed_step, state) do
    with {:ok, _receipt} <-
           Conversations.record_used_refs(state.receipt,
             source_refs: [],
             tool_step_refs: ["tool-step:#{completed_step.id}"],
             memory_evidence: []
           ),
         {:ok, continuation} <- Conversations.tool_continuation_output(completed_step),
         {:ok, _provider_step} <-
           Conversations.start_provider_step(
             state.receipt,
             state.provider.id(),
             state.base_request.model_id
           ) do
      output =
        continuation["output"]
        |> Map.put("outcome_digest", continuation["outcome_digest"])

      # No tool definitions on the report request: the provider must answer in
      # text, and no further tool call can arrive.
      request = %{
        state.base_request
        | input: [],
          previous_response_id: state.response_id,
          tool_outputs: [%ToolOutput{call_id: completed_step.provider_call_id, output: output}],
          tool_definitions: []
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
           continuation_count: state.continuation_count + 1
       }}
    else
      {:error, reason} -> stop_failed(state, reason)
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
      outcome = host_failure_outcome(step, code)

      case Conversations.complete_tool_step(step, outcome) do
        {:ok, completed_step} -> {:limit_reached, completed_step}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp finalize_tool_result({:ok, outcome}, state) do
    step = state.pending_tool.step

    with {:ok, completed_step} <- Conversations.complete_tool_step(step, outcome),
         {:ok, _receipt} <-
           Conversations.record_used_refs(state.receipt,
             source_refs: completed_step.target_receipt_refs,
             tool_step_refs: ["tool-step:#{completed_step.id}"],
             memory_evidence: memory_evidence_usage(completed_step.result)
           ),
         {:ok, continuation} <- Conversations.tool_continuation_output(completed_step),
         {:ok, _provider_step} <-
           Conversations.start_provider_step(
             state.receipt,
             state.provider.id(),
             state.base_request.model_id
           ) do
      output =
        continuation["output"]
        |> Map.put("outcome_digest", continuation["outcome_digest"])

      request = %{
        state.base_request
        | input: [],
          previous_response_id: state.response_id,
          tool_outputs: [%ToolOutput{call_id: completed_step.provider_call_id, output: output}]
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
           continuation_count: state.continuation_count + 1
       }}
    else
      {:error, reason} -> stop_failed(state, reason)
    end
  end

  defp finalize_tool_result({:error, reason}, state), do: stop_failed(state, reason)

  defp finalize_tool_result(other, state),
    do: stop_failed(state, {:unexpected_tool_result, other})

  defp start_provider_task(provider, request) do
    server = self()

    Task.Supervisor.async_nolink(OpenAgents.ProviderTaskSupervisor, fn ->
      provider.stream(request, fn event -> send(server, {:provider_event, event}) end)
    end)
  end

  defp stop_failed(state, reason) do
    :atomics.put(state.cancellation, 1, 1)
    cancel_task(state.task)
    _timer_result = Process.cancel_timer(state.timeout_reference)
    _failure_result = Conversations.fail_turn(state.turn, reason, total_usage(state))
    _incident = report_incident(state, reason)
    {:stop, :normal, state}
  end

  # Every failed turn becomes one durable, owner-scoped incident carrying the
  # real reason — the record that was missing when a delegation "failed" with no
  # visible cause. Expected reasons are recorded but not escalated; anomalous
  # ones open an incident and notify (OpenAgents.Incidents handles the ladder).
  defp report_incident(state, reason) do
    code = reason_code(reason)

    OpenAgents.Incidents.report(%{
      conversation_id: state.turn.conversation_id,
      owner_user_id: state.owner.user_id,
      owner_visitor_id: state.owner.id,
      surface: "text",
      origin: "turn_server",
      correlation_ref: state.turn.id,
      code: code,
      summary: "Text turn failed: #{code}",
      context: %{
        "phase" => Atom.to_string(state.phase),
        "tool_name" => pending_tool_name(state.pending_tool),
        "tool_call_count" => state.tool_call_count,
        "response_id" => state.response_id,
        "reason" => inspect_reason(reason)
      }
    })
  rescue
    _error -> :ok
  end

  # Typed family for a turn death. Never `"unknown"`: a more specific family is
  # always available, and the last resort is `"task_exit"`. The raw shape is
  # kept separately as a bounded `inspect` on the incident context.
  @doc false
  def reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  def reason_code({family, detail}) when is_atom(family) and is_atom(detail),
    do: "#{family}:#{detail}"

  def reason_code({family, _detail}) when is_atom(family), do: Atom.to_string(family)

  def reason_code({family, detail, _extra}) when is_atom(family) and is_atom(detail),
    do: "#{family}:#{detail}"

  def reason_code({family, _detail, _extra}) when is_atom(family), do: Atom.to_string(family)

  def reason_code(reason) when is_binary(reason) do
    if code_token?(reason), do: String.slice(reason, 0, @reason_code_max), else: "task_exit"
  end

  def reason_code(%{__exception__: true, __struct__: module}) when is_atom(module) do
    "task_exit:" <> exception_name(module)
  end

  def reason_code(%{__exception__: true}), do: "task_exit"
  def reason_code(_reason), do: "task_exit"

  defp code_token?(token) do
    byte_size(token) in 1..@reason_code_max and
      Regex.match?(~r/\A[a-z][a-z0-9_]*(?::[a-z0-9_]+)*\z/, token)
  end

  defp exception_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.slice(0, @reason_code_max)
  end

  defp inspect_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 80)
    |> String.slice(0, @reason_inspect_max)
  end

  defp pending_tool_name(%{step: %{tool_name: tool_name}}), do: tool_name
  defp pending_tool_name(_absent), do: nil

  defp cancel_task(task) do
    case Task.shutdown(task, 500) do
      nil -> Task.shutdown(task, :brutal_kill)
      _result -> :ok
    end
  end

  defp total_usage(state), do: merge_usage(state.usage, state.current_usage)

  defp memory_evidence_usage(%{"evidence" => evidence}) when is_map(evidence) do
    case evidence do
      %{"source_ref" => source_ref, "classification" => classification} ->
        [%{"source_ref" => source_ref, "classification" => classification}]

      _invalid ->
        []
    end
  end

  defp memory_evidence_usage(_result), do: []

  defp merge_usage(nil, nil), do: nil
  defp merge_usage(usage, nil), do: usage
  defp merge_usage(nil, usage), do: usage

  defp merge_usage(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value -> left_value + right_value end)
  end

  defp valid_usage?(usage) when map_size(usage) <= 32 do
    with true <-
           Enum.all?(usage, fn {key, value} ->
             is_binary(key) and byte_size(key) <= 64 and is_integer(value) and value >= 0
           end),
         {:ok, encoded} <- Jason.encode(usage) do
      byte_size(encoded) <= 16_384
    else
      _invalid -> false
    end
  end

  defp valid_usage?(_usage), do: false

  defp host_failure_outcome(step, code) do
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
      "status" => "failed",
      "result" => nil,
      "error" => %{"code" => code, "message" => "The turn reached a host execution limit."},
      "target_receipt_refs" => [],
      "attribution_refs" => [],
      "started_at" => now,
      "completed_at" => now
    }
  end

  defp routing_failure_outcome(step, reason) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    status = if reason == :module_policy_refused, do: "refused", else: "unavailable"

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
        "disclosure" => "Sarah module routing policy",
        "implementation_digest" => nil
      },
      "status" => status,
      "result" => nil,
      "error" => %{
        "code" => Atom.to_string(reason),
        "message" => "The captured module route was unavailable or refused by host policy."
      },
      "target_receipt_refs" => [],
      "attribution_refs" => [],
      "started_at" => now,
      "completed_at" => now
    }
  end

  defp host_attribution_policy do
    policy = %{
      "id" => "sarah.attribution.host.v1",
      "version" => 1,
      "mode" => "host_failure_receipt",
      "required" => true
    }

    Map.put(policy, "digest", OpenAgents.Provenance.Canonical.digest!(policy))
  end

  defp normalize_task_exit(:normal), do: :missing_terminal_event
  defp normalize_task_exit(:shutdown), do: :cancelled
  defp normalize_task_exit(_reason), do: {:transport, :provider_task_exited}

  defp via(turn_id), do: {:via, Elixir.Registry, {OpenAgents.TurnRegistry, turn_id}}
end
