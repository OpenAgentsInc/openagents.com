defmodule OpenAgents.VoiceSessions.SessionServer do
  @moduledoc "Supervises one admitted voice generation and its sideband control channel."

  use GenServer

  require Logger

  alias OpenAgents.Voice
  alias OpenAgents.{Conversations, Machines, Repo}
  alias OpenAgents.Conversations.Conversation
  alias OpenAgents.Tools.{ExecutionContext, Runner}
  alias OpenAgents.Tools.Registry, as: ToolRegistry

  alias OpenAgents.Voice.{
    Config,
    OperationalTelemetry,
    ProviderEvent,
    ResponseContext,
    ToolStep,
    Usage
  }

  @maximum_reconnect_attempts 2
  @admission_timeout_ms 30_000
  @maximum_tool_calls 8
  @maximum_local_tool_ms 30_000
  @maximum_live_transcript_bytes 16_000
  @maximum_continuation_bytes 16_000

  # In-call context compaction (issue #68): once the previous response's
  # provider-reported input size crosses the configured threshold, one
  # host-authored text-only response summarizes progress, the summary is
  # persisted durably, old known provider items are deleted, and one bounded
  # system summary item replaces them. Compaction never runs while a tool
  # chain is active or input is queued, and backs off for a few responses
  # after each attempt so it can never loop on itself.
  @compaction_cooldown_responses 3
  @compaction_keep_recent_items 6
  @maximum_compaction_output_tokens 2_048
  @maximum_known_provider_items 64

  @compaction_instructions """
  Host compaction request: this is a maintenance turn, not a reply to the \
  person, and it must produce text only — do not address the person. \
  Summarize this call so far as your own working notes: which requests and \
  steps completed, the exact values, names, numbers, identifiers, and \
  results discovered, what remains open, and the immediate next action. \
  Preserve exact intermediate values verbatim. Do not add new claims, \
  promises, or actions.
  """

  @budget_warning_notice """
  Host notice: this voice call has consumed 80% of its session budget and the \
  host will end it at the ceiling. Wrap up the current work, tell the person \
  the call is near its budget, and suggest restarting voice or continuing in \
  typed chat for anything long.
  """

  def child_spec(session_id) do
    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [session_id]},
      restart: :transient
    }
  end

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  @impl true
  def init(session_id) do
    session = Voice.get_session!(session_id)

    cond do
      session.status in ~w(ended failed) ->
        :ignore

      is_binary(session.provider_session_id) ->
        _failure_result =
          Voice.fail_session(session, session.generation, :runtime_process_restarted)

        :ignore

      true ->
        tool_snapshot = ToolRegistry.current!()

        if tool_snapshot.digest != session.tool_catalog_digest do
          _failure_result =
            Voice.fail_session(session, session.generation, :voice_tool_catalog_changed)

          :ignore
        else
          conversation = Repo.get!(Conversation, session.conversation_id)
          owner = Conversations.get_conversation_owner!(conversation)

          admission_timer = Process.send_after(self(), :admission_timeout, @admission_timeout_ms)

          config =
            Config.current!()
            |> Config.with_context(session.instructions, session.tool_catalog["tools"])

          {:ok,
           %{
             session: session,
             config: config,
             tool_snapshot: tool_snapshot,
             owner: owner,
             sideband: nil,
             sideband_monitor: nil,
             reconnect_attempts: 0,
             admission_timer: admission_timer,
             session_timer: nil,
             closing?: false,
             response_context: nil,
             response_id: nil,
             response_completed?: false,
             pending_tool: nil,
             queued_provider_input_item_id: nil,
             completed_tool_steps: [],
             tool_task: nil,
             tool_cancellation: nil,
             tool_call_count: 0,
             tool_continuation_allowed?: true,
             limit_refused?: false,
             budget_warning_sent?: false,
             assistant_audio: nil,
             live_transcripts: %{},
             last_response_input_tokens: 0,
             compaction: nil,
             compaction_cooldown: 0,
             known_provider_items: []
           }}
        end
    end
  end

  @impl true
  def handle_call({:connect, sdp_offer, safety_identifier}, _from, state) do
    provider = Application.fetch_env!(:sarah, :voice_call_provider)

    with {:ok, admission} <- provider.create(sdp_offer, safety_identifier, state.config),
         {:ok, session} <-
           Voice.attach_provider(
             state.session,
             state.session.generation,
             admission.provider_session_id
           ),
         {:ok, sideband, monitor} <- start_sideband(session, state.config) do
      cancel_timer(state.admission_timer)

      session_timer =
        Process.send_after(self(), :session_timeout, state.config.maximum_session_seconds * 1_000)

      {:reply, {:ok, admission},
       %{
         state
         | session: session,
           sideband: sideband,
           sideband_monitor: monitor,
           session_timer: session_timer
       }}
    else
      {:error, reason} ->
        _failure_result = Voice.fail_session(state.session, state.session.generation, reason)
        {:stop, :normal, {:error, normalize_error(reason)}, %{state | closing?: true}}
    end
  end

  def handle_call({:end_session, reason}, _from, state) do
    cancel_tool_execution(state)
    shutdown_tool_task(state.tool_task)
    close_sideband(state)

    result = Voice.end_session(state.session, state.session.generation, reason)
    {:stop, :normal, result, %{state | closing?: true}}
  end

  def handle_call(:interrupt_response, _from, state) do
    with {:ok, session, _event, _disposition} <-
           Voice.interrupt_response(state.session, state.session.generation),
         :ok <- send_provider_control(state, %{"type" => "response.cancel"}) do
      {:reply, {:ok, session}, %{state | session: session}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:inject_typed_message, content}, _from, state) when is_binary(content) do
    event = %{
      "type" => "conversation.item.create",
      "item" => %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => content}]
      }
    }

    {:reply, send_provider_control(state, event), state}
  end

  def handle_call({:send_control, event}, _from, %{sideband: sideband} = state)
      when is_pid(sideband) do
    provider = Application.fetch_env!(:sarah, :voice_sideband_provider)
    {:reply, provider.send_event(sideband, event), state}
  end

  def handle_call({:send_control, _event}, _from, state),
    do: {:reply, {:error, :sideband_unavailable}, state}

  # Transcript deltas are ephemeral UI projections: accumulated in memory and
  # broadcast live, never persisted.
  @impl true
  def handle_info(
        {:voice_provider_event, session_id, generation,
         %ProviderEvent{kind: kind, payload: payload}},
        %{session: %{id: session_id, generation: generation}} = state
      )
      when kind in [:user_transcript_delta, :assistant_transcript_delta] do
    {:noreply, accumulate_live_transcript(state, kind, payload)}
  end

  def handle_info(
        {:voice_provider_event, session_id, generation, %ProviderEvent{kind: :response_started}},
        %{
          session: %{id: session_id, generation: generation},
          response_context: nil
        } = state
      ) do
    fail_and_stop(state, :voice_response_context_missing)
  end

  def handle_info(
        {:voice_provider_event, session_id, generation, %ProviderEvent{} = provider_event},
        %{session: %{id: session_id, generation: generation}} = state
      ) do
    prior_status = state.session.status

    options =
      case provider_event do
        %ProviderEvent{kind: :response_started} ->
          [
            response_context: state.response_context,
            inherited_tool_steps: state.completed_tool_steps
          ]

        %ProviderEvent{} ->
          []
      end

    case Voice.record_provider_event(state.session, generation, provider_event, options) do
      {:ok, session, _persisted_event, _disposition} when session.status in ~w(ended failed) ->
        close_sideband(state)
        {:stop, :normal, %{state | session: session, closing?: true}}

      {:ok, session, _persisted_event, disposition} ->
        maybe_cancel_interrupted_response(state, prior_status, provider_event)

        next_state = %{
          state
          | session: session,
            live_transcripts: prune_live_transcripts(state.live_transcripts, provider_event),
            known_provider_items:
              track_known_provider_item(state.known_provider_items, provider_event, disposition)
        }

        handle_committed_provider_event(provider_event, disposition, next_state)

      {:error, :stale_voice_generation} ->
        {:noreply, state}

      # The session was already terminally recorded elsewhere (for example
      # startup recovery after an instance replacement). A provider event that
      # trails in is stale, not a new failure to compound.
      {:error, :voice_session_terminal} ->
        Logger.info(
          "voice event after terminal session session=#{state.session.id} " <>
            "kind=#{provider_event.kind}"
        )

        close_sideband(state)
        {:stop, :normal, %{state | closing?: true}}

      {:error, reason} ->
        Logger.error(
          "voice event persistence failed session=#{state.session.id} " <>
            "kind=#{provider_event.kind} reason=#{inspect(reason)}"
        )

        fail_and_stop(state, :event_persistence_failed)
    end
  end

  def handle_info({reference, result}, %{tool_task: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    finalize_tool_result(result, %{state | tool_task: nil, tool_cancellation: nil})
  end

  def handle_info(
        {:DOWN, reference, :process, _process, reason},
        %{tool_task: %{ref: reference}} = state
      ) do
    fail_and_stop(state, normalize_tool_task_exit(reason))
  end

  def handle_info({:voice_provider_event, _session_id, _generation, _event}, state),
    do: {:noreply, state}

  def handle_info(
        {:voice_sideband_connected, session_id, generation, sideband},
        %{session: %{id: session_id, generation: generation}, sideband: sideband} = state
      ) do
    event = %ProviderEvent{kind: :sideband_connected, provider_event_id: nil, payload: %{}}

    case Voice.record_provider_event(state.session, generation, event) do
      {:ok, session, _persisted_event, _disposition} ->
        {:noreply, %{state | session: session, reconnect_attempts: 0}}

      {:error, _reason} ->
        fail_and_stop(state, :sideband_state_failed)
    end
  end

  def handle_info({:voice_sideband_connected, _session_id, _generation, _sideband}, state),
    do: {:noreply, state}

  def handle_info(
        {:voice_sideband_disconnected, session_id, generation},
        %{session: %{id: session_id, generation: generation}} = state
      ) do
    handle_sideband_loss(state)
  end

  def handle_info({:voice_sideband_disconnected, _session_id, _generation}, state),
    do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, sideband, _reason},
        %{sideband_monitor: monitor, sideband: sideband} = state
      ) do
    handle_sideband_loss(state)
  end

  def handle_info({:DOWN, _monitor, :process, _process, _reason}, state),
    do: {:noreply, state}

  def handle_info(
        {:voice_sideband_protocol_error, session_id, generation},
        %{session: %{id: session_id, generation: generation}} = state
      ) do
    fail_and_stop(state, :invalid_provider_event)
  end

  def handle_info(:reconnect_sideband, state) do
    if state.reconnect_attempts >= @maximum_reconnect_attempts do
      fail_and_stop(state, :sideband_reconnect_exhausted)
    else
      case start_sideband(state.session, state.config) do
        {:ok, sideband, monitor} ->
          {:noreply,
           %{
             state
             | sideband: sideband,
               sideband_monitor: monitor,
               reconnect_attempts: state.reconnect_attempts + 1
           }}

        {:error, _reason} ->
          Process.send_after(
            self(),
            :reconnect_sideband,
            reconnect_delay(state.reconnect_attempts)
          )

          {:noreply, %{state | reconnect_attempts: state.reconnect_attempts + 1}}
      end
    end
  end

  def handle_info(:admission_timeout, state), do: fail_and_stop(state, :admission_timeout)

  def handle_info(:session_timeout, state) do
    cancel_tool_execution(state)
    shutdown_tool_task(state.tool_task)
    close_sideband(state)
    _end_result = Voice.end_session(state.session, state.session.generation, "session_timeout")
    {:stop, :normal, %{state | closing?: true}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    cancel_timer(state.admission_timer)
    cancel_timer(state.session_timer)
    cancel_tool_execution(state)
    shutdown_tool_task(state.tool_task)
    close_sideband(state)

    if reason != :normal and not state.closing? do
      _failure_result =
        Voice.fail_session(state.session, state.session.generation, :runtime_process_exited)
    end

    :ok
  end

  defp accumulate_live_transcript(state, kind, %{"item_id" => item_id, "delta" => delta}) do
    role = if kind == :user_transcript_delta, do: "user", else: "assistant"
    accumulated = Map.get(state.live_transcripts, item_id, "")
    state = track_assistant_audio(state, role, item_id)

    if byte_size(accumulated) + byte_size(delta) > @maximum_live_transcript_bytes do
      state
    else
      content = accumulated <> delta
      Voice.broadcast_live_transcript(state.session, item_id, role, content)
      %{state | live_transcripts: Map.put(state.live_transcripts, item_id, content)}
    end
  end

  defp accumulate_live_transcript(state, _kind, _payload), do: state

  # Sarah's audio streams to the browser in real time, so wall-clock time since
  # the first transcript delta of the current assistant item approximates the
  # playback position a barge-in truncation must reconcile to.
  defp track_assistant_audio(state, "assistant", item_id) do
    case state.assistant_audio do
      %{item_id: ^item_id} ->
        state

      _new_or_changed_item ->
        %{
          state
          | assistant_audio: %{
              item_id: item_id,
              started_at: System.monotonic_time(:millisecond)
            }
        }
    end
  end

  defp track_assistant_audio(state, _role, _item_id), do: state

  defp prune_live_transcripts(live_transcripts, %ProviderEvent{
         kind: kind,
         payload: %{"item_id" => item_id}
       })
       when kind in [:user_transcript_final, :assistant_transcript_final] do
    Map.delete(live_transcripts, item_id)
  end

  defp prune_live_transcripts(live_transcripts, _event), do: live_transcripts

  defp start_sideband(session, config) do
    provider = Application.fetch_env!(:sarah, :voice_sideband_provider)

    case provider.start_link(self(), session, config) do
      {:ok, sideband} ->
        Process.unlink(sideband)
        {:ok, sideband, Process.monitor(sideband)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_committed_provider_event(_event, :duplicate, state), do: {:noreply, state}

  defp handle_committed_provider_event(
         %ProviderEvent{
           kind: :user_transcript_final,
           payload: %{"item_id" => provider_input_item_id}
         },
         :created,
         %{pending_tool: pending_tool, queued_provider_input_item_id: nil} = state
       )
       when not is_nil(pending_tool) do
    cancel_tool_execution(state)

    {:noreply,
     %{
       state
       | queued_provider_input_item_id: provider_input_item_id,
         tool_continuation_allowed?: false
     }}
  end

  defp handle_committed_provider_event(
         %ProviderEvent{kind: :user_transcript_final},
         :created,
         %{pending_tool: pending_tool} = state
       )
       when not is_nil(pending_tool) do
    fail_and_stop(state, :overlapping_voice_input)
  end

  defp handle_committed_provider_event(
         %ProviderEvent{
           kind: :user_transcript_final,
           payload: %{"item_id" => provider_input_item_id}
         },
         :created,
         state
       ) do
    begin_response_for_input(provider_input_item_id, state)
  end

  defp handle_committed_provider_event(
         %ProviderEvent{kind: :response_started, payload: %{"response_id" => response_id}},
         :created,
         %{
           response_context: %ResponseContext{}
         } = state
       ) do
    {:noreply,
     %{
       state
       | response_id: response_id,
         response_completed?: false,
         assistant_audio: nil,
         compaction: attach_compaction_response(state.compaction, response_id)
     }}
  end

  # The compaction response's final text is the progress summary: persist it
  # durably on the session row before any pruning happens. A persistence
  # failure abandons the compaction, never the call.
  defp handle_committed_provider_event(
         %ProviderEvent{
           kind: :assistant_transcript_final,
           payload: %{"response_id" => response_id, "content" => content}
         },
         :created,
         %{compaction: %{phase: :running, response_id: response_id} = compaction} = state
       )
       when is_binary(response_id) and is_binary(content) do
    case Voice.record_compaction_summary(state.session, state.session.generation, content) do
      {:ok, session, bounded_summary} ->
        {:noreply,
         %{state | session: session, compaction: %{compaction | summary: bounded_summary}}}

      {:error, reason} ->
        Logger.warning(
          "voice compaction summary persistence failed session=#{state.session.id} " <>
            "reason=#{inspect(reason)}"
        )

        {:noreply,
         %{state | compaction: nil, compaction_cooldown: @compaction_cooldown_responses}}
    end
  end

  defp handle_committed_provider_event(
         %ProviderEvent{kind: :tool_call_requested} = event,
         :created,
         state
       ) do
    begin_tool_execution(event, state)
  end

  defp handle_committed_provider_event(
         %ProviderEvent{kind: :response_completed, payload: payload},
         :created,
         state
       ) do
    handle_response_completion(payload, state)
  end

  defp handle_committed_provider_event(
         %ProviderEvent{kind: kind},
         :created,
         %{pending_tool: pending_tool} = state
       )
       when kind in [:speech_started, :response_cancelled] and not is_nil(pending_tool) do
    cancel_tool_execution(state)
    {:noreply, %{state | response_completed?: true, tool_continuation_allowed?: false}}
  end

  defp handle_committed_provider_event(_event, :created, state), do: {:noreply, state}

  defp begin_response_for_input(provider_input_item_id, state) do
    # New person input supersedes an in-flight compaction: a real turn is
    # never blocked or delayed behind context maintenance. Back off before
    # any retry so the abandoned attempt cannot loop.
    state =
      if is_nil(state.compaction),
        do: state,
        else: %{state | compaction: nil, compaction_cooldown: @compaction_cooldown_responses}

    with {:ok, response_context} <-
           Voice.capture_response_context(
             state.session,
             provider_input_item_id,
             state.tool_snapshot
           ),
         :ok <- send_response_create(state, response_context) do
      {:noreply,
       %{
         state
         | response_context: response_context,
           response_id: nil,
           response_completed?: false,
           queued_provider_input_item_id: nil,
           completed_tool_steps: [],
           tool_call_count: 0,
           tool_continuation_allowed?: true,
           limit_refused?: false
       }}
    else
      {:error, _reason} -> fail_and_stop(state, :voice_response_context_failed)
    end
  end

  defp begin_tool_execution(event, state) do
    response_id = event.payload["response_id"]

    cond do
      is_nil(state.response_context) ->
        fail_and_stop(state, :voice_response_context_missing)

      state.response_id != response_id ->
        fail_and_stop(state, :voice_tool_response_mismatch)

      not is_nil(state.pending_tool) ->
        refuse_overlapping_tool_call(event, state)

      state.tool_call_count >= @maximum_tool_calls ->
        refuse_tool_call_limit(event, state)

      true ->
        with {:ok, requested_step, _disposition} <-
               Voice.request_tool_step(state.session, event, state.tool_snapshot),
             {:ok, running_step, :started} <-
               Voice.start_tool_step(state.session, requested_step) do
          start_tool_task(event.payload["raw_arguments"], running_step, state)
        else
          {:ok, _running_step, :already_running} ->
            fail_and_stop(state, :duplicate_tool_execution_claim)

          {:error, _reason} ->
            fail_and_stop(state, :voice_tool_persistence_failed)
        end
    end
  end

  defp start_tool_task(raw_arguments, %ToolStep{} = running_step, state) do
    call = %{
      call_id: running_step.provider_call_id,
      name: running_step.tool_name,
      version: running_step.tool_version,
      raw_arguments: raw_arguments
    }

    context = state.response_context

    execution_context = %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:#{state.session.conversation_id}",
      # Voice carries the same computer authorities AND the same machine
      # approval receipts as a text turn: pairing a machine in the browser is
      # the operator's approval, so effectful computer_run/computer_agent work
      # from voice too. The machine's own local policy stays the real guardrail
      # (the audit's "machine is the policy authority").
      authorities:
        MapSet.new([
          "conversation.read",
          "github.read",
          "memory.read",
          "memory.write",
          "computer.control",
          "module.discover",
          "work.delegate"
        ]),
      approval_receipts:
        Machines.approval_receipts(
          state.owner.user_id,
          "conversation:#{state.session.conversation_id}"
        ),
      surface: "voice",
      conversation_id: state.session.conversation_id,
      current_user_message_id: context.user_message_id,
      owner_visitor_id: state.owner.id,
      memory_snapshot_ref: context.memory_snapshot_ref,
      profile_memory_snapshot_ref: context.profile_memory_snapshot_ref
    }

    cancellation = :atomics.new(1, [])
    snapshot = state.tool_snapshot

    task =
      Task.Supervisor.async_nolink(OpenAgents.ProviderTaskSupervisor, fn ->
        Runner.run(snapshot, call, execution_context,
          timeout_ms: @maximum_local_tool_ms,
          cancel?: fn -> :atomics.get(cancellation, 1) == 1 end
        )
      end)

    {:noreply,
     %{
       state
       | pending_tool: %{step: running_step, raw_arguments: raw_arguments},
         tool_task: task,
         tool_cancellation: cancellation,
         tool_call_count: state.tool_call_count + 1,
         tool_continuation_allowed?: true
     }}
  end

  defp finalize_tool_result({:ok, outcome}, %{pending_tool: pending_tool} = state) do
    with {:ok, completed_step} <-
           Voice.complete_tool_step(state.session, pending_tool.step, outcome) do
      updated_state = %{state | pending_tool: %{pending_tool | step: completed_step}}

      cond do
        updated_state.response_completed? and updated_state.tool_continuation_allowed? ->
          continue_after_tool(updated_state)

        updated_state.response_completed? ->
          # The chain will not continue (barge-in or a newer user turn), but the
          # provider conversation must never keep a function_call item without
          # an output: deliver the terminal (usually cancelled) outcome without
          # driving a response.
          _orphan_result = send_terminal_tool_output(updated_state, completed_step)

          updated_state
          |> clear_completed_tool()
          |> maybe_begin_queued_response()

        true ->
          {:noreply, updated_state}
      end
    else
      {:error, _reason} -> fail_and_stop(state, :voice_tool_persistence_failed)
    end
  end

  defp finalize_tool_result({:error, _reason}, state),
    do: fail_and_stop(state, :voice_tool_runner_failed)

  defp finalize_tool_result(_result, state),
    do: fail_and_stop(state, :voice_tool_runner_failed)

  defp handle_response_completion(payload, state) do
    state = %{
      state
      | last_response_input_tokens: response_input_tokens(payload),
        compaction_cooldown: max(state.compaction_cooldown - 1, 0)
    }

    if Usage.over_budget?(state.session.usage) do
      cancel_tool_execution(state)
      shutdown_tool_task(state.tool_task)
      close_sideband(state)

      _end_result =
        Voice.end_session(state.session, state.session.generation, "usage_budget_reached")

      {:stop, :normal, %{state | closing?: true}}
    else
      state = maybe_send_budget_warning(state)
      handle_response_completion_within_budget(payload, state)
    end
  end

  # One host notice at 80% of the session budget lets the model wrap up and
  # tell the person before over_budget?/1 ends the call at the ceiling.
  defp maybe_send_budget_warning(%{budget_warning_sent?: true} = state), do: state

  defp maybe_send_budget_warning(state) do
    if Usage.near_budget?(state.session.usage) do
      _notice_result =
        send_provider_control(state, %{
          "type" => "conversation.item.create",
          "item" => %{
            "type" => "message",
            "role" => "system",
            "content" => [%{"type" => "input_text", "text" => @budget_warning_notice}]
          }
        })

      %{state | budget_warning_sent?: true}
    else
      state
    end
  end

  # The compaction response finished with a persisted summary: prune old known
  # provider items, inject one bounded system summary item, and release the
  # cycle. The cooldown starts here, so the compaction response can never
  # re-trigger itself.
  defp handle_response_completion_within_budget(
         %{"response_id" => response_id, "status" => "completed"},
         %{compaction: %{phase: :running, response_id: response_id, summary: summary}} = state
       )
       when is_binary(response_id) and is_binary(summary) do
    state = prune_compacted_items(state, summary)

    :ok =
      OperationalTelemetry.emit(:compaction, state.session, %{event_kind: "compaction_completed"})

    {:noreply, clear_compaction_cycle(state)}
  end

  # The compaction response ended without a usable summary (barge-in
  # cancellation, empty transcript, persistence race): never prune without an
  # injected summary. Release the cycle and back off.
  defp handle_response_completion_within_budget(
         %{"response_id" => response_id},
         %{compaction: %{response_id: response_id}} = state
       )
       when is_binary(response_id) do
    :ok =
      OperationalTelemetry.emit(:compaction, state.session, %{event_kind: "compaction_abandoned"})

    {:noreply, clear_compaction_cycle(state)}
  end

  defp handle_response_completion_within_budget(
         %{"response_id" => response_id, "status" => "completed"},
         %{response_id: response_id, pending_tool: nil, limit_refused?: true} = state
       ) do
    _report_result = send_response_create(state, state.response_context, "none")

    {:noreply,
     %{
       state
       | response_id: nil,
         response_completed?: false,
         limit_refused?: false
     }}
  end

  defp handle_response_completion_within_budget(
         %{"response_id" => response_id, "status" => "completed"},
         %{response_id: response_id, pending_tool: nil} = state
       ) do
    if compaction_ready?(state) do
      start_compaction(state)
    else
      {:noreply,
       %{
         state
         | response_context: nil,
           response_id: nil,
           response_completed?: false,
           completed_tool_steps: [],
           tool_call_count: 0,
           tool_continuation_allowed?: true,
           limit_refused?: false
       }}
    end
  end

  defp handle_response_completion_within_budget(
         %{"response_id" => response_id, "status" => "completed"},
         %{response_id: response_id, pending_tool: %{step: %ToolStep{} = step}} = state
       ) do
    updated_state = %{state | response_completed?: true}

    if step.status in ~w(succeeded failed refused cancelled unavailable interrupted) and
         updated_state.tool_continuation_allowed? do
      continue_after_tool(updated_state)
    else
      {:noreply, updated_state}
    end
  end

  defp handle_response_completion_within_budget(
         %{"response_id" => response_id},
         %{response_id: response_id, pending_tool: pending_tool} = state
       ) do
    cancel_tool_execution(state)

    case pending_tool do
      nil ->
        state
        |> Map.merge(%{
          response_context: nil,
          response_id: nil,
          response_completed?: false,
          completed_tool_steps: [],
          tool_call_count: 0,
          tool_continuation_allowed?: true,
          limit_refused?: false
        })
        |> maybe_begin_queued_response()

      %{step: %ToolStep{status: status} = step}
      when status in ~w(succeeded failed refused cancelled unavailable interrupted) ->
        # The response was cancelled after its tool already reached a terminal
        # outcome. Deliver the output so the provider conversation keeps no
        # orphan function_call item, then release the cycle.
        _orphan_result = send_terminal_tool_output(state, step)

        state
        |> clear_completed_tool()
        |> maybe_begin_queued_response()

      _still_running ->
        {:noreply,
         %{
           state
           | response_completed?: true,
             tool_continuation_allowed?: false
         }}
    end
  end

  defp handle_response_completion_within_budget(%{"response_id" => response_id}, state)
       when is_binary(response_id) do
    {:noreply, state}
  end

  defp handle_response_completion_within_budget(_payload, state),
    do: fail_and_stop(state, :voice_response_mismatch)

  defp send_terminal_tool_output(state, %ToolStep{} = step) do
    with {:ok, output} <- encoded_tool_continuation(step) do
      send_provider_control(state, %{
        "type" => "conversation.item.create",
        "item" => %{
          "type" => "function_call_output",
          "call_id" => step.provider_call_id,
          "output" => output
        }
      })
    end
  end

  # The durable ToolStep keeps the full result; the provider conversation gets
  # a bounded copy so tool output cannot balloon per-response context and cost.
  defp encoded_tool_continuation(%ToolStep{} = step) do
    with {:ok, continuation} <- Voice.tool_continuation_output(step),
         {:ok, output} <- Jason.encode(continuation) do
      if byte_size(output) <= @maximum_continuation_bytes do
        {:ok, output}
      else
        bounded =
          put_in(continuation, ["output", "result"], %{
            "truncated" => true,
            "note" =>
              "The full result exceeded the voice continuation size bound and was " <>
                "truncated. Its salient beginning follows.",
            "preview" => bounded_utf8(output, div(@maximum_continuation_bytes, 2))
          })

        Jason.encode(bounded)
      end
    end
  end

  defp bounded_utf8(binary, maximum) do
    sliced = binary_part(binary, 0, min(byte_size(binary), maximum))
    trim_to_valid_utf8(sliced)
  end

  defp trim_to_valid_utf8(<<>>), do: ""

  defp trim_to_valid_utf8(binary) do
    if String.valid?(binary),
      do: binary,
      else: trim_to_valid_utf8(binary_part(binary, 0, byte_size(binary) - 1))
  end

  defp continue_after_tool(%{pending_tool: %{step: %ToolStep{} = step}} = state) do
    with :ok <- send_terminal_tool_output(state, step),
         :ok <- send_response_create(state, state.response_context) do
      {:noreply,
       %{
         state
         | response_id: nil,
           response_completed?: false,
           completed_tool_steps: state.completed_tool_steps ++ [step],
           pending_tool: nil,
           tool_task: nil,
           tool_cancellation: nil
       }}
    else
      {:error, _reason} -> fail_and_stop(state, :voice_tool_continuation_failed)
    end
  end

  defp refuse_overlapping_tool_call(%ProviderEvent{payload: payload}, state) do
    _ =
      send_tool_refusal(
        state,
        payload["call_id"],
        "parallel_tool_calls_not_supported",
        "Only one tool call may be in flight at a time. Call this tool again after the current one completes."
      )

    {:noreply, state}
  end

  # Hitting the per-turn tool budget refuses the call instead of failing the
  # session; once the active response finishes, one tool-free response is
  # driven so the model reports what it already has instead of going silent.
  defp refuse_tool_call_limit(%ProviderEvent{payload: payload}, state) do
    _ =
      send_tool_refusal(
        state,
        payload["call_id"],
        "tool_call_limit_reached",
        "This turn reached the host limit of #{@maximum_tool_calls} tool calls. " <>
          "Do not call tools again this turn; report what you already have."
      )

    {:noreply, %{state | limit_refused?: true}}
  end

  defp send_tool_refusal(state, call_id, code, message) do
    refusal = %{
      "schema" => "sarah.tool_continuation.v1",
      "call_id" => call_id,
      "outcome_digest" => nil,
      "output" => %{
        "status" => "refused",
        "result" => nil,
        "error" => %{
          "code" => code,
          "message" => message
        },
        "executor" => %{
          "id" => "sarah.host",
          "disclosure" => "Sarah host execution limits"
        },
        "target_receipt_refs" => [],
        "attribution_refs" => []
      }
    }

    send_provider_control(state, %{
      "type" => "conversation.item.create",
      "item" => %{
        "type" => "function_call_output",
        "call_id" => call_id,
        "output" => Jason.encode!(refusal)
      }
    })
  end

  defp clear_completed_tool(state) do
    %{
      state
      | pending_tool: nil,
        response_context: nil,
        response_id: nil,
        response_completed?: false,
        completed_tool_steps: [],
        tool_call_count: 0,
        tool_continuation_allowed?: true,
        limit_refused?: false
    }
  end

  defp maybe_begin_queued_response(%{queued_provider_input_item_id: nil} = state),
    do: {:noreply, state}

  defp maybe_begin_queued_response(
         %{queued_provider_input_item_id: provider_input_item_id} = state
       ),
       do: begin_response_for_input(provider_input_item_id, state)

  defp response_input_tokens(%{"usage" => %{"input_tokens" => tokens}})
       when is_integer(tokens) and tokens >= 0,
       do: tokens

  defp response_input_tokens(_payload), do: 0

  # Provider item ids the server has actually seen, oldest first, so
  # compaction deletes only items it can name. Host-created items
  # (function_call_output, system notices) carry no id and are never tracked
  # or deleted.
  defp track_known_provider_item(
         known_items,
         %ProviderEvent{kind: kind, payload: %{"item_id" => item_id}},
         :created
       )
       when kind in [:user_transcript_final, :assistant_transcript_final, :tool_call_requested] and
              is_binary(item_id) do
    ((known_items -- [item_id]) ++ [item_id])
    |> Enum.take(-@maximum_known_provider_items)
  end

  defp track_known_provider_item(known_items, _event, _disposition), do: known_items

  # Compaction only starts at a quiet response boundary: no compaction already
  # in flight, no active tool chain, no queued input, cooldown expired, and
  # the previous response's provider-reported input size at or past the
  # threshold. The frozen response context is reused for the single
  # host-authored maintenance response, mirroring the tool-limit report path.
  defp compaction_ready?(state) do
    is_nil(state.compaction) and
      is_nil(state.pending_tool) and
      is_nil(state.queued_provider_input_item_id) and
      state.compaction_cooldown == 0 and
      match?(%ResponseContext{}, state.response_context) and
      state.last_response_input_tokens >=
        Application.fetch_env!(:sarah, :voice_compaction_input_token_threshold)
  end

  defp start_compaction(state) do
    case send_provider_control(state, %{
           "type" => "response.create",
           "response" => %{
             "instructions" => @compaction_instructions,
             "output_modalities" => ["text"],
             "max_output_tokens" => @maximum_compaction_output_tokens,
             "tool_choice" => "none"
           }
         }) do
      :ok ->
        :ok =
          OperationalTelemetry.emit(:compaction, state.session, %{
            event_kind: "compaction_started"
          })

        {:noreply,
         %{
           state
           | response_id: nil,
             response_completed?: false,
             completed_tool_steps: [],
             tool_call_count: 0,
             tool_continuation_allowed?: true,
             limit_refused?: false,
             compaction: %{phase: :awaiting_start, response_id: nil, summary: nil}
         }}

      {:error, _reason} ->
        # Sideband unavailable: skip this compaction attempt and release the
        # cycle normally; a later response boundary can trigger again.
        {:noreply,
         %{
           state
           | response_context: nil,
             response_id: nil,
             response_completed?: false,
             completed_tool_steps: [],
             tool_call_count: 0,
             tool_continuation_allowed?: true,
             limit_refused?: false
         }}
    end
  end

  defp attach_compaction_response(%{phase: :awaiting_start} = compaction, response_id),
    do: %{compaction | phase: :running, response_id: response_id}

  defp attach_compaction_response(compaction, _response_id), do: compaction

  # Delete provider items older than the most recent N the server knows by
  # id, then inject exactly one bounded system summary item carrying the
  # persisted summary. Items the server never saw an id for cannot be deleted
  # and are left in place.
  defp prune_compacted_items(state, summary) do
    drop_count = max(length(state.known_provider_items) - @compaction_keep_recent_items, 0)
    {delete, keep} = Enum.split(state.known_provider_items, drop_count)

    Enum.each(delete, fn item_id ->
      _delete_result =
        send_provider_control(state, %{
          "type" => "conversation.item.delete",
          "item_id" => item_id
        })
    end)

    _summary_result =
      send_provider_control(state, %{
        "type" => "conversation.item.create",
        "item" => %{
          "type" => "message",
          "role" => "system",
          "content" => [
            %{
              "type" => "input_text",
              "text" => "Earlier conversation compacted. Summary: " <> summary
            }
          ]
        }
      })

    %{state | known_provider_items: keep}
  end

  defp clear_compaction_cycle(state) do
    %{
      state
      | compaction: nil,
        compaction_cooldown: @compaction_cooldown_responses,
        response_context: nil,
        response_id: nil,
        response_completed?: false,
        completed_tool_steps: [],
        tool_call_count: 0,
        tool_continuation_allowed?: true,
        limit_refused?: false
    }
  end

  defp send_response_create(state, %ResponseContext{} = context, tool_choice \\ "auto") do
    send_provider_control(state, %{
      "type" => "response.create",
      "response" => %{
        "instructions" => context.instructions,
        "max_output_tokens" =>
          Application.fetch_env!(:sarah, :voice_maximum_response_output_tokens),
        "tool_choice" => tool_choice
      }
    })
  end

  defp cancel_tool_execution(%{tool_cancellation: nil}), do: :ok

  defp cancel_tool_execution(%{tool_cancellation: cancellation}) do
    :atomics.put(cancellation, 1, 1)
    :ok
  end

  defp normalize_tool_task_exit(:normal), do: :voice_tool_result_missing
  defp normalize_tool_task_exit(:shutdown), do: :voice_tool_cancelled
  defp normalize_tool_task_exit(_reason), do: :voice_tool_task_exited

  defp handle_sideband_loss(%{closing?: true} = state), do: {:noreply, state}

  defp handle_sideband_loss(state) do
    demonitor(state.sideband_monitor)

    event = %ProviderEvent{kind: :sideband_disconnected, provider_event_id: nil, payload: %{}}

    case Voice.record_provider_event(state.session, state.session.generation, event) do
      {:ok, session, _persisted_event, _disposition} ->
        Process.send_after(self(), :reconnect_sideband, reconnect_delay(state.reconnect_attempts))

        {:noreply, %{state | session: session, sideband: nil, sideband_monitor: nil}}

      {:error, _reason} ->
        fail_and_stop(state, :sideband_state_failed)
    end
  end

  defp reconnect_delay(attempt), do: min(250 * (attempt + 1), 1_000)

  defp send_provider_control(%{sideband: sideband}, event) when is_pid(sideband) do
    provider = Application.fetch_env!(:sarah, :voice_sideband_provider)
    provider.send_event(sideband, event)
  end

  defp send_provider_control(_state, _event), do: {:error, :sideband_unavailable}

  defp maybe_cancel_interrupted_response(
         %{sideband: sideband} = state,
         "responding",
         %ProviderEvent{kind: :speech_started}
       )
       when is_pid(sideband) do
    # Truncate the interrupted assistant item to the approximate playback
    # position first, so the provider conversation never retains speech the
    # person did not hear, then cancel generation.
    truncate_unheard_assistant_audio(state)
    _cancel_result = send_provider_control(state, %{"type" => "response.cancel"})
    :ok
  end

  defp maybe_cancel_interrupted_response(_state, _prior_status, _event), do: :ok

  defp truncate_unheard_assistant_audio(
         %{assistant_audio: %{item_id: item_id, started_at: started_at}} = state
       ) do
    audio_end_ms = max(System.monotonic_time(:millisecond) - started_at, 0)

    _truncate_result =
      send_provider_control(state, %{
        "type" => "conversation.item.truncate",
        "item_id" => item_id,
        "content_index" => 0,
        "audio_end_ms" => audio_end_ms
      })

    :ok
  end

  defp truncate_unheard_assistant_audio(_state), do: :ok

  defp fail_and_stop(state, reason) do
    cancel_tool_execution(state)
    shutdown_tool_task(state.tool_task)
    close_sideband(state)
    _failure_result = Voice.fail_session(state.session, state.session.generation, reason)
    _incident = report_voice_incident(state, reason)
    {:stop, :normal, %{state | closing?: true}}
  end

  # A failed voice session is a durable incident too, so a caller who asks "why
  # did that voice session fail?" is answerable from evidence rather than "I
  # can't see it". Owner-scoped; the escalation ladder decides severity/notify.
  defp report_voice_incident(state, reason) do
    code =
      case normalize_error(reason) do
        atom when is_atom(atom) -> Atom.to_string(atom)
        {family, _detail} when is_atom(family) -> Atom.to_string(family)
      end

    OpenAgents.Incidents.report(%{
      conversation_id: state.session.conversation_id,
      owner_user_id: state.owner.user_id,
      owner_visitor_id: state.owner.id,
      surface: "voice",
      origin: "voice_session",
      correlation_ref: state.session.id,
      code: code,
      summary: "Voice session failed: #{code}",
      context: %{"generation" => state.session.generation}
    })
  rescue
    _error -> :ok
  end

  defp close_sideband(%{sideband: sideband}) when is_pid(sideband) do
    provider = Application.fetch_env!(:sarah, :voice_sideband_provider)
    _close_result = provider.close(sideband)
    :ok
  end

  defp close_sideband(_state), do: :ok

  defp demonitor(nil), do: :ok

  defp demonitor(monitor) do
    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _cancel_result = Process.cancel_timer(timer)
    :ok
  end

  defp shutdown_tool_task(nil), do: :ok

  defp shutdown_tool_task(task) do
    case Task.shutdown(task, 500) do
      nil ->
        _shutdown_result = Task.shutdown(task, :brutal_kill)
        :ok

      _result ->
        :ok
    end
  end

  defp normalize_error({:http_status, status}) when is_integer(status),
    do: {:provider_rejected_call, status}

  defp normalize_error(reason) when is_atom(reason), do: reason
  defp normalize_error(_reason), do: :voice_connection_failed

  defp via(session_id),
    do: {:via, Registry, {OpenAgents.VoiceSessionRegistry, session_id}}
end
