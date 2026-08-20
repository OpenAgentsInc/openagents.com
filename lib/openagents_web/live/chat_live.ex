defmodule OpenAgentsWeb.ChatLive do
  use OpenAgentsWeb, :sarah_live_view

  alias OpenAgents.{
    Accounts,
    Conversations,
    DataRights,
    ProfileMemory,
    Turns,
    Voice,
    VoiceSessions
  }

  alias OpenAgents.ComputerActivity
  alias OpenAgents.Conversations.Message
  alias OpenAgents.Voice.Config, as: VoiceConfig
  alias OpenAgents.Voice.Recordings
  alias OpenAgents.Work
  alias OpenAgentsWeb.ToolActivity

  # The sidebar's calls and work sections are bounded projections, not
  # unbounded lists: the last eight of each, recomputed on the same PubSub
  # broadcasts that drive the transcript.
  @sidebar_section_limit 8

  # One live delegation panel at a time: a newer delegation supersedes the
  # current one, which collapses to a summary line. Superseded summaries are a
  # bounded ephemeral list, cleared on dismiss.
  @delegation_summary_limit 3

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok, conversation} = Conversations.ensure_conversation(current_user)
    owner = Conversations.get_conversation_owner!(conversation)
    {messages, has_older?} = Conversations.list_messages(conversation)
    active_turn = Conversations.active_turn(conversation)
    voice_config = VoiceConfig.current!()
    voice_session = if voice_config.enabled?, do: Voice.active_session(conversation), else: nil

    if connected?(socket) do
      :ok = Conversations.subscribe(conversation)
      :ok = ProfileMemory.subscribe(owner)
      :ok = Voice.subscribe(conversation)
      :ok = Work.subscribe(conversation.id)
      :ok = ComputerActivity.subscribe(conversation.id)
    end

    socket =
      socket
      |> assign(:page_title, "Sarah")
      |> assign(:reset_enabled?, DataRights.reset_enabled?())
      |> assign(:conversation, conversation)
      |> assign(:memory_owner, owner)
      |> assign(:memory_open?, false)
      |> assign(:memory_records, [])
      |> assign(:memory_status, nil)
      |> assign(:pending_memory_action, nil)
      |> assign(:has_older?, has_older?)
      |> assign(:oldest_message_id, first_id(messages))
      |> assign(:active_turn, active_turn)
      |> assign(:message_queue, [])
      |> assign(:voice_enabled?, voice_config.enabled?)
      |> assign(:recording_config, Recordings.config())
      |> assign(:voice_session, voice_session)
      |> assign(:recent_jobs, Work.recent_jobs(conversation, @sidebar_section_limit))
      |> assign(:tool_activity, tool_activity(active_turn, voice_session))
      |> assign(:message_activity, message_activity(messages))
      |> assign(:job_rollups, Conversations.list_work_job_rollups_by_message(messages))
      |> assign(:composer_error, nil)
      |> assign(:form, composer_form())
      |> assign(:privacy_delete_form, to_form(%{"confirmation" => ""}, as: :privacy))
      |> assign(:live_voice_items, MapSet.new())
      |> assign(:paced_voice_items, MapSet.new())
      |> assign(:delegation, nil)
      |> assign(:delegation_summaries, [])
      |> assign(:delegation_collapsed, false)
      |> stream(:messages, messages)

    {:ok, socket}
  end

  @impl true
  def handle_event("send_message", %{"chat" => %{"message" => content}}, socket) do
    case voice_route(socket) do
      {:voice, voice_session} -> send_typed_message_into_voice(socket, voice_session, content)
      {:text, next_socket} -> start_text_turn(next_socket, content)
    end
  end

  def handle_event("cancel_turn", _params, %{assigns: %{active_turn: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_turn", _params, socket) do
    _cancel_result = Turns.cancel(socket.assigns.active_turn.id)
    {:noreply, socket}
  end

  def handle_event("cancel_delegation", _params, socket) do
    _cancel = OpenAgents.Work.cancel_active_delegations(socket.assigns.conversation.id)
    {:noreply, socket}
  end

  # Drop a not-yet-started queued message before it runs.
  def handle_event("dequeue_message", %{"id" => id}, socket) do
    id = String.to_integer(id)
    queue = Enum.reject(socket.assigns.message_queue, &(&1.id == id))
    {:noreply, assign(socket, :message_queue, queue)}
  end

  def handle_event("load_older", _params, socket) do
    {messages, has_older?} =
      Conversations.list_messages(socket.assigns.conversation, socket.assigns.oldest_message_id)

    socket =
      messages
      |> Enum.reverse()
      |> Enum.reduce(push_event(socket, "history:prepend", %{}), fn message, next_socket ->
        stream_insert(next_socket, :messages, message, at: 0)
      end)
      |> assign(:has_older?, has_older?)
      |> assign(:oldest_message_id, first_id(messages) || socket.assigns.oldest_message_id)
      |> assign(
        :message_activity,
        Map.merge(socket.assigns.message_activity, message_activity(messages))
      )
      |> assign(
        :job_rollups,
        Map.merge(
          socket.assigns.job_rollups,
          Conversations.list_work_job_rollups_by_message(messages)
        )
      )

    {:noreply, socket}
  end

  def handle_event("toggle_memory", _params, socket) do
    if socket.assigns.memory_open? do
      {messages, has_older?} = Conversations.list_messages(socket.assigns.conversation)

      {:noreply,
       socket
       |> assign(:memory_open?, false)
       |> assign(:pending_memory_action, nil)
       |> assign(:memory_status, nil)
       |> assign(:has_older?, has_older?)
       |> assign(:oldest_message_id, first_id(messages))
       |> stream(:messages, messages, reset: true)
       |> push_event("composer:focus", %{})}
    else
      {:noreply,
       socket
       |> assign(:memory_open?, true)
       |> assign(:pending_memory_action, nil)
       |> assign(:memory_status, nil)
       |> reload_memory()}
    end
  end

  def handle_event("correct_memory", %{"record_id" => record_id, "claim" => claim}, socket) do
    owner = socket.assigns.memory_owner

    result =
      with {:ok, record} <- ProfileMemory.get(owner, record_id),
           true <- record.status == "active",
           {:ok, _corrected} <-
             ProfileMemory.correct(owner, record.id, record.generation, %{
               category: record.category,
               claim: claim,
               creator: "user_explicit",
               owner_asserted: true,
               sources: [],
               provenance: %{
                 "operation" => "first_party_ui_correction",
                 "supersedes_record_id" => record.id
               }
             }) do
        :ok
      else
        false -> {:error, :memory_not_active}
        {:error, reason} -> {:error, reason}
      end

    {:noreply, memory_result(socket, result, "Memory corrected and previous wording retained.")}
  end

  def handle_event("request_memory_forget", params, socket) do
    case pending_action(socket.assigns.memory_owner, params) do
      {:ok, pending} ->
        {:noreply,
         socket
         |> assign(:pending_memory_action, pending)
         |> assign(:memory_status, nil)}

      {:error, _reason} ->
        {:noreply, assign(socket, :memory_status, {:error, "That memory is no longer active."})}
    end
  end

  def handle_event("cancel_memory_action", _params, socket) do
    {:noreply, assign(socket, :pending_memory_action, nil)}
  end

  # The live delegation panel is ephemeral: dismissing it clears the whole
  # projection. The durable event header in the transcript stays the record.
  def handle_event("dismiss_delegation", _params, socket) do
    {:noreply,
     socket
     |> assign(:delegation, nil)
     |> assign(:delegation_summaries, [])}
  end

  # Collapse state is a server assign, not a client attribute toggle: the rail
  # re-renders on every streamed chunk, so a DOM-only `data-collapsed` snapped
  # back open on the next patch. Holding it here keeps the rail collapsed until
  # the reader expands it again.
  def handle_event("toggle_delegation_rail", _params, socket) do
    {:noreply, assign(socket, :delegation_collapsed, !socket.assigns.delegation_collapsed)}
  end

  def handle_event(
        "confirm_memory_forget",
        _params,
        %{assigns: %{pending_memory_action: nil}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("confirm_memory_forget", _params, socket) do
    pending = socket.assigns.pending_memory_action
    result = ProfileMemory.forget_active(socket.assigns.memory_owner, pending.selector)

    message =
      case result do
        {:ok, %{disposition: "already_absent"}} ->
          "Those memories were already absent."

        {:ok, %{records: records}} ->
          "Forgot #{length(records)} memory record(s) in this account."

        {:error, _reason} ->
          "Sarah could not forget that selection. Refresh and try again."
      end

    status = if match?({:ok, _result}, result), do: :ok, else: :error

    {:noreply,
     socket
     |> assign(:pending_memory_action, nil)
     |> assign(:memory_status, {status, message})
     |> reload_memory()}
  end

  @impl true
  def handle_info({:message_updated, message}, socket) do
    {:noreply,
     socket
     |> clear_live_voice_item(message.provider_item_id)
     |> refresh_job_rollup(message)
     |> stream_insert(:messages, message)}
  end

  def handle_info(
        {:voice_live_transcript, %{conversation_id: conversation_id} = live},
        %{assigns: %{conversation: %{id: conversation_id}}} = socket
      ) do
    paced_voice_items =
      if live.role == "assistant",
        do: MapSet.put(socket.assigns.paced_voice_items, live.item_id),
        else: socket.assigns.paced_voice_items

    {:noreply,
     socket
     |> assign(:live_voice_items, MapSet.put(socket.assigns.live_voice_items, live.item_id))
     |> assign(:paced_voice_items, paced_voice_items)
     |> stream_insert(:messages, live_voice_message(live))}
  end

  def handle_info({:voice_live_transcript, _other_conversation}, socket),
    do: {:noreply, socket}

  def handle_info({:turn_updated, turn}, socket) do
    if turn.status in ["completed", "failed", "cancelled"] do
      # The active turn ended: clear it, surface any error, and immediately start
      # the next queued message so a stacked run continues without the owner
      # re-sending.
      socket
      |> assign(:active_turn, nil)
      |> assign(:tool_activity, [])
      |> assign(:composer_error, turn.error_message)
      |> push_event("composer:focus", %{})
      |> advance_queue()
    else
      {:noreply,
       socket
       |> assign(:active_turn, turn)
       |> assign(:tool_activity, Conversations.list_tool_step_activity(turn))}
    end
  end

  def handle_info({:tool_activity_updated, turn_id}, socket) do
    case socket.assigns.active_turn do
      %{id: ^turn_id, assistant_message_id: assistant_message_id} = turn ->
        steps = Conversations.list_tool_step_activity(turn)

        # A stream row does not re-render because an outside assign changed, so
        # the message is re-inserted to pull the new activity into its row. Tool
        # steps can complete before any text arrives, in which case no delta
        # would otherwise refresh it.
        socket =
          socket
          |> assign(:tool_activity, steps)
          |> assign(
            :message_activity,
            Map.put(socket.assigns.message_activity, assistant_message_id, steps)
          )

        case Conversations.get_message(assistant_message_id) do
          nil -> {:noreply, socket}
          message -> {:noreply, stream_insert(socket, :messages, message)}
        end

      _inactive_or_different_turn ->
        {:noreply, socket}
    end
  end

  def handle_info({:profile_memory_updated, _result}, socket) do
    if socket.assigns.memory_open?,
      do: {:noreply, reload_memory(socket)},
      else: {:noreply, socket}
  end

  def handle_info(
        {:voice_session_updated, %{conversation_id: conversation_id} = voice_session},
        %{assigns: %{conversation: %{id: conversation_id}}} = socket
      ) do
    activity =
      cond do
        socket.assigns.active_turn -> socket.assigns.tool_activity
        voice_session.status in ~w(ended failed) -> []
        true -> Voice.list_tool_step_activity(voice_session)
      end

    socket =
      if voice_session.status in ~w(ended failed),
        do: clear_all_live_voice_items(socket),
        else: socket

    {:noreply,
     socket
     |> assign(:voice_session, voice_session)
     |> assign(:tool_activity, activity)}
  end

  def handle_info({:voice_session_updated, _other_session}, socket), do: {:noreply, socket}

  # Job lifecycle broadcasts (create, running, terminal) refresh the sidebar's
  # bounded work section; the terminal broadcast also carries the report
  # message id that turns a row into a jump-to-report anchor.
  def handle_info(
        {:work_job_updated, %{conversation_id: conversation_id}},
        %{assigns: %{conversation: %{id: conversation_id}}} = socket
      ) do
    {:noreply,
     assign(
       socket,
       :recent_jobs,
       Work.recent_jobs(socket.assigns.conversation, @sidebar_section_limit)
     )}
  end

  def handle_info({:work_job_updated, _other_job}, socket), do: {:noreply, socket}

  # ── Live delegation projection (OpenAgents.ComputerActivity) ────────────────────
  # A bounded ephemeral projection of one streamed computer delegation. Only
  # one live panel at a time: a newer delegation supersedes the current one,
  # which collapses to a bounded summary line. Nothing here is persisted; the
  # durable tool-step outcome remains the record, and a reload mid-delegation
  # degrades to the quiet tool-activity status (chunks with no matching start
  # are ignored rather than reconstructed).

  def handle_info({:computer_live_started, event}, socket) do
    summaries =
      case socket.assigns.delegation do
        nil ->
          socket.assigns.delegation_summaries

        superseded ->
          Enum.take(
            [delegation_summary(superseded) | socket.assigns.delegation_summaries],
            @delegation_summary_limit
          )
      end

    {:noreply,
     socket
     |> assign(:delegation, %{
       ref: event.ref,
       kind: event.kind,
       machine_name: event.machine_name,
       agent_id: event.agent_id,
       started_at: event.started_at,
       state: :running,
       status: "running",
       stop_reason: "",
       duration_ms: nil,
       truncated?: false
     })
     |> assign(:delegation_summaries, summaries)}
  end

  # Chunk text never enters an assign: it is pushed to the log hooks, which
  # append it client-side. The server-side caps in OpenAgents.ComputerActivity
  # bound what can ever arrive here.
  def handle_info({:computer_live_chunk, %{ref: ref, text: text}}, socket) do
    case socket.assigns.delegation do
      %{ref: ^ref, state: :running} ->
        {:noreply, push_event(socket, "delegation:chunk", %{ref: ref, text: text})}

      _stale_or_absent ->
        {:noreply, socket}
    end
  end

  def handle_info({:computer_live_truncated, %{ref: ref}}, socket) do
    case socket.assigns.delegation do
      %{ref: ^ref} = delegation ->
        {:noreply, assign(socket, :delegation, %{delegation | truncated?: true})}

      _stale_or_absent ->
        {:noreply, socket}
    end
  end

  def handle_info({:computer_live_terminal, %{ref: ref} = event}, socket) do
    case socket.assigns.delegation do
      %{ref: ^ref} = delegation ->
        {:noreply,
         assign(socket, :delegation, %{
           delegation
           | state: :terminal,
             status: event.status,
             stop_reason: event.stop_reason,
             duration_ms: event.duration_ms
         })}

      _superseded_or_absent ->
        summaries =
          Enum.map(socket.assigns.delegation_summaries, fn
            %{ref: ^ref} = summary -> %{summary | status: event.status}
            summary -> summary
          end)

        {:noreply, assign(socket, :delegation_summaries, summaries)}
    end
  end

  def handle_info({:voice_tool_activity_updated, session_id, _step_id}, socket) do
    case socket.assigns.voice_session do
      %{id: ^session_id} = session when is_nil(socket.assigns.active_turn) ->
        {:noreply, assign(socket, :tool_activity, Voice.list_tool_step_activity(session))}

      _inactive_or_different_session ->
        {:noreply, socket}
    end
  end

  # One active turn per conversation is preserved: a message sent while a turn is
  # already running is queued and started when that turn reaches a terminal
  # state, so the composer never has to block. Ordering is FIFO.
  defp start_text_turn(%{assigns: %{active_turn: active}} = socket, content)
       when active != nil,
       do: enqueue_message(socket, content)

  defp start_text_turn(%{assigns: %{message_queue: [_ | _]}} = socket, content),
    do: enqueue_message(socket, content)

  defp start_text_turn(socket, content), do: launch_turn(socket, content)

  # The actual turn launch, past the queue guards — also used to start the next
  # queued message once the active turn ends.
  defp launch_turn(socket, content) do
    case Conversations.create_turn(socket.assigns.conversation, content) do
      {:ok, records} ->
        _ = Turns.start(records.turn.id)

        socket =
          socket
          |> stream_insert(:messages, records.user_message)
          |> stream_insert(:messages, records.assistant_message)
          |> assign(:active_turn, records.turn)
          |> assign(:tool_activity, [])
          |> assign(:composer_error, nil)
          |> assign(:form, composer_form())
          |> push_event("composer:clear", %{})
          |> push_event("chat:scroll-bottom", %{})

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :composer_error, error_message(reason))}
    end
  end

  @maximum_queued_messages 10

  # Append a message to run after the active turn(s), so the composer never
  # blocks. Validated at enqueue; the per-minute rate limit is still enforced
  # when the message actually launches (Conversations.create_turn).
  defp enqueue_message(socket, content) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" ->
        {:noreply, socket}

      byte_size(trimmed) > 8_000 ->
        {:noreply, assign(socket, :composer_error, error_message(:message_too_long))}

      length(socket.assigns.message_queue) >= @maximum_queued_messages ->
        {:noreply,
         assign(
           socket,
           :composer_error,
           "That's the most messages I can line up. One will start soon."
         )}

      true ->
        item = %{id: System.unique_integer([:positive, :monotonic]), content: trimmed}

        {:noreply,
         socket
         |> assign(:message_queue, socket.assigns.message_queue ++ [item])
         |> assign(:composer_error, nil)
         |> assign(:form, composer_form())
         |> push_event("composer:clear", %{})
         |> push_event("chat:scroll-bottom", %{})}
    end
  end

  # Start the next queued message, if any. Called when the active turn ends.
  defp advance_queue(socket) do
    case socket.assigns.message_queue do
      [] -> {:noreply, socket}
      [next | rest] -> launch_turn(assign(socket, :message_queue, rest), next.content)
    end
  end

  defp paced_live_transcript?(
         %Message{role: "assistant", modality: "voice", provider_item_id: item_id} = message,
         paced_items
       ) do
    message.status == "streaming" or
      (is_binary(item_id) and MapSet.member?(paced_items, item_id))
  end

  defp paced_live_transcript?(_message, _paced_items), do: false

  defp live_voice_message(live) do
    %Message{
      id: "voice-live-#{live.item_id}",
      role: live.role,
      content: live.content,
      status: if(live.role == "assistant", do: "streaming", else: "complete"),
      modality: "voice",
      provider_item_id: live.item_id,
      interrupted: false
    }
  end

  defp clear_live_voice_item(socket, nil), do: socket

  defp clear_live_voice_item(socket, item_id) do
    if MapSet.member?(socket.assigns.live_voice_items, item_id) do
      socket
      |> stream_delete_by_dom_id(:messages, "messages-voice-live-#{item_id}")
      |> assign(:live_voice_items, MapSet.delete(socket.assigns.live_voice_items, item_id))
    else
      socket
    end
  end

  defp clear_all_live_voice_items(socket) do
    socket.assigns.live_voice_items
    |> Enum.reduce(socket, fn item_id, next_socket ->
      stream_delete_by_dom_id(next_socket, :messages, "messages-voice-live-#{item_id}")
    end)
    |> assign(:live_voice_items, MapSet.new())
  end

  defp composer_form, do: to_form(%{"message" => ""}, as: :chat)
  # Keyed by assistant message so the transcript can show what Sarah did next to
  # what she said, and so a reload rebuilds it from PostgreSQL.
  defp message_activity(messages) do
    messages
    |> Enum.filter(&(&1.role == "assistant"))
    |> Enum.map(& &1.id)
    |> Conversations.list_tool_step_activity_by_message()
  end

  defp first_id([message | _messages]), do: message.id
  defp first_id([]), do: nil
  defp tool_activity(nil, nil), do: []

  defp tool_activity(turn, _voice_session) when not is_nil(turn),
    do: Conversations.list_tool_step_activity(turn)

  defp tool_activity(nil, voice_session), do: Voice.list_tool_step_activity(voice_session)

  defp reload_memory(socket) do
    case ProfileMemory.export(socket.assigns.memory_owner) do
      {:ok, export} -> assign(socket, :memory_records, export["records"])
      {:error, _reason} -> assign(socket, :memory_status, {:error, "Memory is unavailable."})
    end
  end

  defp memory_result(socket, :ok, message) do
    socket
    |> assign(:memory_status, {:ok, message})
    |> reload_memory()
  end

  defp memory_result(socket, {:error, reason}, _message) do
    assign(socket, :memory_status, {:error, memory_error(reason)})
  end

  defp pending_action(owner, %{"kind" => "record", "id" => record_id}) do
    with {:ok, record} <- ProfileMemory.get(owner, record_id),
         true <- record.status == "active" do
      {:ok,
       %{
         label: ~s(Forget "#{record.claim}"?),
         selector: %{
           "mode" => "record",
           "record_id" => record.id,
           "expected_generation" => record.generation
         }
       }}
    else
      _invalid -> {:error, :not_found}
    end
  end

  defp pending_action(_owner, %{"kind" => "category", "category" => category})
       when category in ~w(name role project preference constraint other) do
    {:ok,
     %{
       label: "Forget every active #{category} memory in this account?",
       selector: %{"mode" => "category", "category" => category}
     }}
  end

  defp pending_action(_owner, %{"kind" => "all"}) do
    {:ok,
     %{
       label: "Forget every active profile memory in this account?",
       selector: %{"mode" => "all"}
     }}
  end

  defp pending_action(_owner, _params), do: {:error, :invalid_action}

  defp memory_error(:duplicate_memory), do: "That exact memory is already active."

  defp memory_error(:memory_conflict_requires_correction),
    do: "That category has a conflicting active memory."

  defp memory_error(:invalid_claim), do: "Enter a non-empty correction under 500 bytes."

  defp memory_error({:memory_policy_rejected, _reason}),
    do: "That correction was refused by the memory privacy policy."

  defp memory_error(_reason), do: "Sarah could not update that memory. Refresh and try again."

  defp memory_date(nil), do: "DATE UNAVAILABLE"
  defp memory_date(timestamp), do: String.slice(timestamp, 0, 10)

  # A live voice session keeps the call open and reads typed messages as
  # first-class conversation input. A stale active record whose runtime
  # process is gone is closed honestly so typed chat proceeds normally.
  defp voice_route(%{assigns: %{voice_session: voice_session}} = socket)
       when not is_nil(voice_session) and
              voice_session.status in ~w(connecting listening responding interrupted reconnecting) do
    case VoiceSessions.whereis(voice_session.id) do
      nil ->
        ended =
          case VoiceSessions.end_session(voice_session, "voice_runtime_missing") do
            {:ok, ended_session} -> ended_session
            {:error, _reason} -> voice_session
          end

        {:text, assign(socket, :voice_session, ended)}

      _process ->
        {:voice, voice_session}
    end
  end

  defp voice_route(socket), do: {:text, socket}

  defp send_typed_message_into_voice(socket, voice_session, content) do
    case Conversations.create_voice_context_message(socket.assigns.conversation, content) do
      {:ok, message} ->
        _injection_result = VoiceSessions.inject_typed_message(voice_session, message)

        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:composer_error, nil)
         |> assign(:form, composer_form())
         |> push_event("composer:clear", %{})
         |> push_event("chat:scroll-bottom", %{})}

      {:error, reason} ->
        {:noreply, assign(socket, :composer_error, error_message(reason))}
    end
  end

  defp voice_server_status(nil), do: "idle"
  defp voice_server_status(voice_session), do: voice_session.status

  defp voice_end_reason(%{status: "ended", termination_reason: reason}) when is_binary(reason),
    do: reason

  defp voice_end_reason(_voice_session), do: nil
  defp voice_generation(nil), do: nil
  defp voice_generation(voice_session), do: voice_session.generation

  defp error_message(:empty_message), do: "Write a message before sending."

  defp error_message(:message_too_long),
    do: "That message is too long. Keep it under 8,000 bytes."

  defp error_message(:rate_limited), do: "Please wait a moment before sending another message."
  defp error_message(:turn_in_progress), do: "Sarah is still responding."
  defp error_message(%Ecto.Changeset{}), do: "Sarah could not save that message."
  defp error_message(_reason), do: "Sarah could not accept that message."

  # Only Sarah writes Markdown. A person's message is shown exactly as typed, so
  # asterisks they meant literally stay literal, and a voice transcript is
  # speech rather than a document.
  defp markdown?(%{role: "assistant", modality: modality}), do: modality != "voice"
  defp markdown?(_message), do: false

  defp role_label("user"), do: "YOU"
  defp role_label("assistant"), do: "SARAH"
  defp role_label("system"), do: "SYSTEM"

  defp status_label("streaming"), do: "RESPONDING"
  defp status_label("failed"), do: "INCOMPLETE"
  defp status_label("cancelled"), do: "STOPPED"
  defp status_label(_status), do: nil

  # A deep-work report message just landed: pull its bounded rollup projection
  # so the row can render as a "Worked for <duration>" header.
  defp refresh_job_rollup(socket, %Message{work_job_id: job_id} = message)
       when is_binary(job_id) do
    assign(
      socket,
      :job_rollups,
      Map.merge(
        socket.assigns.job_rollups,
        Conversations.list_work_job_rollups_by_message([message])
      )
    )
  end

  defp refresh_job_rollup(socket, _message), do: socket

  defp rollup_title(%{started_at: started_at, completed_at: completed_at}) do
    case ToolActivity.duration(started_at, completed_at) do
      nil -> "Worked"
      duration -> "Worked for #{duration}"
    end
  end

  # Job statuses mapped onto the existing status hues; never hidden.
  defp rollup_status(%{status: "completed"}), do: "succeeded"
  defp rollup_status(%{status: "failed"}), do: "failed"
  defp rollup_status(%{status: "interrupted"}), do: "interrupted"
  defp rollup_status(%{status: "budget_exhausted"}), do: "unavailable"
  defp rollup_status(_rollup), do: "unavailable"

  defp rollup_status_note(%{status: "completed"}), do: nil

  defp rollup_status_note(%{status: status}),
    do: status |> String.upcase() |> String.replace("_", " ")

  defp memory_status_variant({:error, _message}), do: :danger
  defp memory_status_variant(_status), do: :success

  defp memory_badge_variant("active"), do: :success
  defp memory_badge_variant(_status), do: :default

  defp message_status_variant("streaming"), do: :info
  defp message_status_variant(_status), do: :warning

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} title="Chat" current_scope={@current_scope}>
      <div
        id="sarah-app"
        class="app-shell chat-shell"
        data-mobile-open="false"
        phx-hook=".SidebarShell"
      >
        <.sidebar
          current_user={@current_user}
          memory_open?={@memory_open?}
          reset_enabled?={@reset_enabled?}
          recent_jobs={@recent_jobs}
        />

        <%!-- Mobile only: closes the overlay on tap. The menu button remains the
              accessible toggle; this is a pointer convenience, not a control. --%>
        <div id="sidebar-scrim" class="sidebar-scrim" aria-hidden="true"></div>

        <main class="app-main">
          <.mobile_header />

          <section
            :if={!@memory_open?}
            id="transcript"
            class="transcript"
            aria-label="Conversation transcript"
            phx-hook=".TranscriptScroll"
          >
            <div :if={@has_older?} class="history-control">
              <.text_button id="load-older" phx-click="load_older">
                <.icon name="history" /> LOAD EARLIER MESSAGES
              </.text_button>
            </div>

            <%!-- Cloned into each rendered code block by the TranscriptActions
                  hook, so the copy affordance ships from the template (vendored
                  glyph, accessible name) rather than being built in script. --%>
            <template id="code-copy-template">
              <.button
                variant={:ghost}
                size={:xs}
                class="code-copy"
                aria-label="Copy code"
                data-copy-kind="code"
              >
                <.icon name="copy" />
              </.button>
            </template>

            <div
              id="messages"
              class="message-list"
              phx-update="stream"
              aria-live="polite"
              phx-hook=".TranscriptActions"
            >
              <.message_row
                :for={{dom_id, message} <- @streams.messages}
                id={dom_id}
                message={message}
                paced_items={@paced_voice_items}
                activity={Map.get(@message_activity, message.id, [])}
                rollup={Map.get(@job_rollups, message.id)}
              />
            </div>

            <%!-- Voice tool activity has no assistant message to attach to until a
                  transcript lands, so a live session's steps render at the tail of
                  the transcript. Text turns attach activity to their assistant
                  message row instead, so this never duplicates them. --%>
            <section
              :if={@active_turn == nil and @tool_activity != []}
              id="live-tool-activity"
              class="tool-activity tool-activity--live"
              role="status"
              aria-live="polite"
              aria-atomic="false"
              aria-label="Sarah activity"
            >
              <.activity_event
                :for={activity <- @tool_activity}
                id={"live-tool-activity-step-#{activity.id}"}
                activity={activity}
              />
            </section>

            <%!-- Below the desktop breakpoint the live delegation projection
                  renders inline at the transcript tail on the event-header
                  expansion pattern, instead of as a rail. One projection,
                  two placements; the stylesheet shows exactly one. --%>
            <.delegation_inline :if={@delegation} delegation={@delegation} />
          </section>

          <.memory_manager
            :if={@memory_open?}
            memory_records={@memory_records}
            memory_status={@memory_status}
            pending_memory_action={@pending_memory_action}
            privacy_delete_form={@privacy_delete_form}
            recording_config={@recording_config}
          />

          <footer :if={!@memory_open?} class="composer-region">
            <section
              :if={@voice_enabled?}
              id="voice-controller"
              class="voice-controller voice-controller--in-composer"
              phx-hook="VoiceController"
              data-server-status={voice_server_status(@voice_session)}
              data-server-end-reason={voice_end_reason(@voice_session)}
              data-server-generation={voice_generation(@voice_session)}
              data-text-turn-active={to_string(@active_turn != nil)}
              data-recording-enabled={to_string(@recording_config.enabled?)}
              data-recording-timeslice-ms={@recording_config.timeslice_ms}
            >
              <.voice_status />
              <.composer_stack
                form={@form}
                composer_error={@composer_error}
                active_turn={@active_turn}
                message_queue={@message_queue}
                voice_enabled?={true}
              />
              <audio id="voice-output" class="voice-output" autoplay playsinline></audio>
            </section>

            <.composer_stack
              :if={!@voice_enabled?}
              form={@form}
              composer_error={@composer_error}
              active_turn={@active_turn}
              message_queue={@message_queue}
              voice_enabled?={false}
            />
          </footer>
        </main>

        <%!-- Desktop only (≥1280px): the slim live delegation rail, the shell's
              third grid column. Ephemeral chrome — rendered only while a
              delegation is in flight or recently finished, never permanent. --%>
        <.delegation_rail
          :if={@delegation != nil or @delegation_summaries != []}
          delegation={@delegation}
          summaries={@delegation_summaries}
          collapsed={@delegation_collapsed}
        />
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarShell">
        export default {
          storageKey: "sarah:sidebar",
          mounted() {
            this.collapsed = localStorage.getItem(this.storageKey) === "collapsed"
            this.mobileOpen = false
            this.apply()
            // Delegated so the listeners survive any LiveView patch inside the
            // shell. Collapse and the mobile overlay are pure client state; the
            // server never needs to know.
            this.el.addEventListener("click", event => {
              if (event.target.closest("#sidebar-toggle")) {
                this.collapsed = !this.collapsed
                localStorage.setItem(this.storageKey, this.collapsed ? "collapsed" : "expanded")
                this.apply()
              } else if (event.target.closest("#mobile-menu")) {
                this.mobileOpen = !this.mobileOpen
                this.apply()
              } else if (
                event.target.closest("#sidebar-scrim") ||
                  (this.mobileOpen && event.target.closest(".sidebar-row__hit"))
              ) {
                this.mobileOpen = false
                this.apply()
              }
            })
            this.onKeydown = event => {
              if (event.key === "Escape" && this.mobileOpen) {
                this.mobileOpen = false
                this.apply()
              }
            }
            window.addEventListener("keydown", this.onKeydown)
            // Scroll does not bubble, so the section area's scrolling is
            // observed with a capturing listener on the shell; it survives
            // LiveView patches the same way the click delegation does.
            this.el.addEventListener("scroll", event => {
              if (event.target.id === "sidebar-sections") this.applyScrollEdges()
            }, { capture: true, passive: true })
            this.applyScrollEdges()
          },
          updated() {
            this.apply()
            this.applyScrollEdges()
          },
          destroyed() { window.removeEventListener("keydown", this.onKeydown) },
          // A sticky section label earns its hairline only after rows have
          // actually scrolled beneath it (DESIGN.md, scroll-edge hairline).
          applyScrollEdges() {
            const container = this.el.querySelector("#sidebar-sections")
            if (!container) return
            const top = container.getBoundingClientRect().top
            container.querySelectorAll(".sidebar-section").forEach(section => {
              const label = section.querySelector(".sidebar-section-label")
              if (!label) return
              if (section.getBoundingClientRect().top < top - 0.5) {
                label.setAttribute("data-scroll-edge", "stuck")
              } else {
                label.removeAttribute("data-scroll-edge")
              }
            })
          },
          apply() {
            const sidebar = this.el.querySelector("#sidebar")
            if (sidebar) sidebar.setAttribute("data-state", this.collapsed ? "collapsed" : "expanded")
            this.el.setAttribute("data-mobile-open", this.mobileOpen ? "true" : "false")
            const toggle = this.el.querySelector("#sidebar-toggle")
            if (toggle) toggle.setAttribute("aria-expanded", this.collapsed ? "false" : "true")
            const menu = this.el.querySelector("#mobile-menu")
            if (menu) menu.setAttribute("aria-expanded", this.mobileOpen ? "true" : "false")
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".TranscriptScroll">
        export default {
          mounted() {
            this.preserveNextUpdate = false
            // A copied message link lands here as /chat#<row id>: scroll the
            // row into view and flash it once. The flash animation is killed
            // by the global reduced-motion rule, so the mechanic stays
            // motion-safe.
            const anchor = window.location.hash.slice(1)
            const target = anchor && document.getElementById(anchor)
            if (target && this.el.contains(target)) {
              target.scrollIntoView({ block: "center" })
              target.setAttribute("data-flash", "")
              setTimeout(() => target.removeAttribute("data-flash"), 1600)
            } else {
              this.scrollToBottom()
            }
            this.handleEvent("chat:scroll-bottom", () => this.scrollToBottom())
            this.handleEvent("history:prepend", () => { this.preserveNextUpdate = true })
          },
          beforeUpdate() {
            this.previousHeight = this.el.scrollHeight
            this.previousTop = this.el.scrollTop
            this.wasNearBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 120
          },
          updated() {
            if (this.preserveNextUpdate) {
              this.el.scrollTop = this.previousTop + (this.el.scrollHeight - this.previousHeight)
              this.preserveNextUpdate = false
            } else if (this.wasNearBottom) {
              this.scrollToBottom()
            }
          },
          scrollToBottom() {
            this.el.scrollTop = this.el.scrollHeight
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".TranscriptActions">
        export default {
          // One delegated hook serves every copy affordance in the transcript:
          // the message toolbar's copy/copy-link buttons and the copy pill it
          // clones into each rendered code block (LiveView owns this DOM, so a
          // patch can wipe injected pills; the observer re-injects them).
          mounted() {
            this.el.addEventListener("click", event => {
              const button = event.target.closest("[data-copy-kind]")
              if (!button || !this.el.contains(button)) return
              const row = button.closest(".message-row")
              switch (button.dataset.copyKind) {
                case "message": {
                  const content = row && row.querySelector(".message-content")
                  if (content) this.copy(button, content.innerText.trim())
                  break
                }
                case "link": {
                  if (row) {
                    const link = `${location.origin}${location.pathname}#${row.id}`
                    this.copy(button, link)
                  }
                  break
                }
                case "code": {
                  const well = button.closest("pre")
                  const code = well && well.querySelector("code")
                  if (code) this.copy(button, code.innerText)
                  break
                }
              }
            })
            this.injectCodeCopy()
            this.observer = new MutationObserver(() => this.injectCodeCopy())
            this.observer.observe(this.el, { childList: true, subtree: true })
          },
          destroyed() {
            if (this.observer) this.observer.disconnect()
          },
          copy(button, text) {
            if (!navigator.clipboard) return
            navigator.clipboard.writeText(text).then(() => {
              button.setAttribute("data-copied", "")
              setTimeout(() => button.removeAttribute("data-copied"), 1500)
            }).catch(() => {})
          },
          injectCodeCopy() {
            const template = document.getElementById("code-copy-template")
            if (!template) return
            for (const pre of this.el.querySelectorAll(".message-markdown pre")) {
              if (!pre.querySelector("[data-copy-kind='code']")) {
                pre.appendChild(template.content.cloneNode(true))
              }
            }
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
        export default {
          mounted() {
            this.card = this.el.closest(".composer-card")
            this.resize()
            this.el.addEventListener("input", () => this.resize())
            this.el.addEventListener("keydown", event => {
              if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
                event.preventDefault()
                if (!this.el.disabled && this.el.value.trim()) this.el.form.requestSubmit()
              }
            })
            this.handleEvent("composer:focus", () => this.el.focus())
            // LiveView reads FormData during the submit event. Clearing here
            // races that read and can send an empty message.
            this.handleEvent("composer:clear", () => this.clear())
          },
          updated() { this.resize() },
          clear() {
            this.el.value = ""
            this.resize()
          },
          resize() {
            this.el.style.height = "auto"
            this.el.style.height = `${Math.min(this.el.scrollHeight, 208)}px`
            // One line keeps the card's single collapsed row; a newline or
            // wrapped growth flips data-expanded and the grid-template-areas
            // swap reorganizes the card. Re-measured on every input and patch,
            // so LiveView updates cannot strand a stale attribute.
            if (!this.oneLine) {
              const style = getComputedStyle(this.el)
              this.oneLine =
                parseFloat(style.lineHeight) +
                parseFloat(style.paddingTop) +
                parseFloat(style.paddingBottom)
            }
            const expanded =
              this.el.value.includes("\n") || this.el.scrollHeight > this.oneLine + 2
            if (this.card) this.card.toggleAttribute("data-expanded", expanded)
            this.el.toggleAttribute("data-overflowing", this.el.scrollHeight > 208)
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DelegationLog">
        // Record/unit separators frame structured tool events inside the plain
        // text stream (see sarah-computer-controller AcpAgent.renderUpdate).
        // A frame is one line beginning with RS whose fields split on US;
        // everything else is agent prose. This hook renders frames as
        // collapsible tool cards and notes, and prose as text — never HTML.
        const RS = String.fromCharCode(30)
        const US = String.fromCharCode(31)

        const decode64 = (value) => {
          try {
            return new TextDecoder().decode(Uint8Array.from(atob(value), (c) => c.charCodeAt(0)))
          } catch {
            return ""
          }
        }

        export default {
          mounted() {
            this.buffer = ""
            this.tools = new Map()
            this.prose = null
            this.handleEvent("delegation:chunk", ({ ref, text }) => {
              if (this.el.dataset.ref !== ref) return
              const follow =
                this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 40
              this.ingest(text)
              if (follow) this.el.scrollTop = this.el.scrollHeight
            })
          },

          // Flush prose immediately; hold only an incomplete trailing frame.
          ingest(text) {
            this.buffer += text
            while (this.buffer.length > 0) {
              if (this.buffer[0] === RS) {
                const nl = this.buffer.indexOf("\n")
                if (nl === -1) break
                const line = this.buffer.slice(1, nl)
                this.buffer = this.buffer.slice(nl + 1)
                this.renderFrame(line)
              } else {
                const next = this.buffer.indexOf(RS)
                const chunk = next === -1 ? this.buffer : this.buffer.slice(0, next)
                this.buffer = next === -1 ? "" : this.buffer.slice(next)
                this.appendProse(chunk)
              }
            }
          },

          appendProse(text) {
            if (text === "") return
            if (!this.prose || this.prose.parentNode !== this.el || this.el.lastChild !== this.prose) {
              this.prose = document.createElement("span")
              this.prose.className = "deleg-prose"
              this.el.appendChild(this.prose)
            }
            this.prose.appendChild(document.createTextNode(text))
          },

          renderFrame(line) {
            const fields = line.split(US)
            if (fields[0] === "T") {
              this.renderTool(fields)
            } else if (fields[0] === "N") {
              this.renderNote(fields)
            }
            this.prose = null
          },

          // T | id | phase(0 start,1 done,2 failed) | kind | b64 title | b64 detail
          renderTool([, id, phase, kind, b64title, b64detail]) {
            const title = decode64(b64title || "")
            const detail = decode64(b64detail || "")
            let card = this.tools.get(id)
            if (!card) {
              card = this.buildTool(id, kind, title, detail)
              this.tools.set(id, card)
              this.el.appendChild(card.root)
            }
            if (phase === "1" || phase === "2") {
              card.root.dataset.status = phase === "1" ? "succeeded" : "failed"
              if (detail !== "") {
                card.out.textContent = detail
                card.out.hidden = false
              }
            }
          },

          buildTool(id, kind, title, command) {
            const root = document.createElement("details")
            root.className = "deleg-tool"
            root.dataset.status = "running"
            root.dataset.kind = kind || "other"

            const summary = document.createElement("summary")
            summary.className = "deleg-tool__summary"
            const dot = document.createElement("span")
            dot.className = "deleg-tool__dot"
            const label = document.createElement("span")
            label.className = "deleg-tool__label"
            label.textContent = this.kindLabel(kind) || title || "tool"
            summary.appendChild(dot)
            summary.appendChild(label)
            if (command !== "") {
              const inline = document.createElement("code")
              inline.className = "deleg-tool__inline"
              inline.textContent = command
              summary.appendChild(inline)
            }

            const body = document.createElement("div")
            body.className = "deleg-tool__body"
            const cmd = document.createElement("pre")
            cmd.className = "deleg-tool__cmd"
            cmd.textContent = command !== "" ? "$ " + command : title
            const out = document.createElement("pre")
            out.className = "deleg-tool__out"
            out.hidden = true
            body.appendChild(cmd)
            body.appendChild(out)

            root.appendChild(summary)
            root.appendChild(body)
            return { root, out }
          },

          kindLabel(kind) {
            const labels = {
              execute: "Terminal",
              read: "Read",
              edit: "Edit",
              search: "Search",
              fetch: "Fetch",
              think: "Think",
              move: "Move",
              delete: "Delete"
            }
            return labels[kind] || ""
          },

          // N | b64 text | tone(info|warn|error)
          renderNote([, b64text, tone]) {
            const note = document.createElement("div")
            note.className = "deleg-note"
            note.dataset.tone = tone || "info"
            note.textContent = decode64(b64text || "")
            this.el.appendChild(note)
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DelegationClock">
        export default {
          // Elapsed time ticks client-side from the broadcast start instant,
          // so the server never re-renders just to move a clock.
          mounted() {
            this.tick()
            this.timer = setInterval(() => this.tick(), 1000)
          },
          destroyed() { clearInterval(this.timer) },
          tick() {
            const started = Date.parse(this.el.dataset.startedAt)
            if (Number.isNaN(started)) return
            const total = Math.max(0, Math.floor((Date.now() - started) / 1000))
            const minutes = Math.floor(total / 60)
            const seconds = total % 60
            this.el.textContent = minutes > 0 ? `${minutes}m ${seconds}s` : `${seconds}s`
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
        export default {
          // Server timestamps render in UTC; the browser is the only place
          // that knows the viewer's timezone, so localize here from the
          // machine-readable `datetime` attribute. Re-runs on every patch so a
          // streamed-in row is localized too.
          mounted() { this.localize() },
          updated() { this.localize() },
          localize() {
            const iso = this.el.getAttribute("datetime")
            const at = iso && new Date(iso)
            if (!at || Number.isNaN(at.getTime())) return
            this.el.textContent = at.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :current_user, :map, required: true
  attr :memory_open?, :boolean, required: true
  attr :reset_enabled?, :boolean, required: true
  attr :recent_jobs, :list, required: true

  # The conversation's chrome. The sidebar navigates Sarah's surfaces —
  # computers, memory, leaderboard, admin, export — never conversations; one
  # conversation remains the product (DESIGN.md, Layout). Rows are the
  # stretched-anchor pattern: the hit control owns the whole row and the
  # accessible name, the visible content beneath is pointer-transparent, and
  # any future trailing control floats back above it at its own z-index.
  defp sidebar(assigns) do
    ~H"""
    <aside id="sidebar" class="sidebar" data-state="expanded" aria-label="OpenAgents surfaces">
      <header class="sidebar-header">
        <span class="brand-name">OpenAgents</span>
        <.button
          id="sidebar-toggle"
          variant={:ghost}
          size={:sm}
          class="sidebar-toggle !size-9 !min-h-0 !min-w-0 !p-0"
          aria-label="Toggle sidebar"
          aria-expanded="true"
          aria-controls="sidebar"
        >
          <.icon name="sidebar" class="sidebar-toggle__collapse !text-[1.25rem]" />
          <.icon name="sidebar" class="sidebar-toggle__expand !text-[1.25rem]" />
        </.button>
      </header>

      <nav id="sidebar-nav" class="sidebar-nav" aria-label="OpenAgents surfaces">
        <div class="sidebar-row">
          <.link
            id="open-computers"
            navigate="/computers"
            class="sidebar-row__hit"
            aria-label="Computers"
          ></.link>
          <span class="sidebar-row__content">
            <span class="sidebar-row__icon"><.icon name="desktop" /></span>
            <span class="sidebar-row__label">Computers</span>
          </span>
        </div>

        <div class="sidebar-row" data-selected={@memory_open?}>
          <button
            id="toggle-memory"
            type="button"
            class="sidebar-row__hit"
            phx-click="toggle_memory"
            aria-expanded={to_string(@memory_open?)}
            aria-controls="memory-manager"
            aria-label={if @memory_open?, do: "Return to conversation", else: "Memory"}
          ></button>
          <span class="sidebar-row__content">
            <span class="sidebar-row__icon">
              <.icon name={if @memory_open?, do: "arrow-left", else: "brain"} />
            </span>
            <span class="sidebar-row__label">
              {if @memory_open?, do: "Return to conversation", else: "Memory"}
            </span>
          </span>
        </div>

        <div class="sidebar-row">
          <.link
            id="open-leaderboard"
            navigate="/leaderboard"
            class="sidebar-row__hit"
            aria-label="Leaderboard"
          ></.link>
          <span class="sidebar-row__content">
            <span class="sidebar-row__icon"><.icon name="trophy-top" /></span>
            <span class="sidebar-row__label">Leaderboard</span>
          </span>
        </div>

        <div class="sidebar-row">
          <.link
            id="export-atif"
            href="/data/export/atif"
            download
            class="sidebar-row__hit"
            aria-label="Export"
          ></.link>
          <span class="sidebar-row__content">
            <span class="sidebar-row__icon"><.icon name="download" /></span>
            <span class="sidebar-row__label">Export</span>
          </span>
        </div>
      </nav>

      <%!-- Calls and work: bounded, durable-backed projections (last eight
            each), refreshed by the same PubSub broadcasts that drive the
            transcript. A row whose evidence is a durable transcript message is
            a stretched anchor to it; a row with no target is stated, not
            linked. Empty sections keep their labels and say so honestly. --%>
      <div id="sidebar-sections" class="sidebar-sections">
        <section :if={@recent_jobs != []} id="sidebar-work" class="sidebar-section" aria-label="Work">
          <h2 class="sidebar-section-label scroll-edge-hairline">WORK</h2>
          <.sidebar_status_row
            :for={job <- @recent_jobs}
            id={"sidebar-job-#{job.id}"}
            target_message_id={job.report_message_id}
            dot_state={job_dot_state(job)}
            title={job_title(job)}
            meta={job_meta(job)}
            data-status={job.status}
          />
        </section>
      </div>

      <nav
        :if={Accounts.admin?(@current_user) or @reset_enabled?}
        id="sidebar-admin"
        class="sidebar-nav"
        aria-label="Administration and data"
      >
        <div :if={Accounts.admin?(@current_user)} class="sidebar-row">
          <.link id="open-admin" navigate="/admin" class="sidebar-row__hit" aria-label="Admin"></.link>
          <span class="sidebar-row__content">
            <span class="sidebar-row__icon"><.icon name="shield-lock" /></span>
            <span class="sidebar-row__label">Admin</span>
          </span>
        </div>

        <.form
          :if={@reset_enabled?}
          for={%{}}
          id="reset-conversation-form"
          action="/data/reset"
          method="delete"
          class="sidebar-row"
        >
          <.button
            id="reset-conversation"
            variant={:ghost}
            size={:sm}
            type="submit"
            data-confirm="Delete every message and memory for this account?"
            aria-label="Reset"
            class="sidebar-row__hit"
          >{" "}</.button>
          <span class="sidebar-row__content">
            <span class="sidebar-row__icon"><.icon name="trash" /></span>
            <span class="sidebar-row__label">Reset</span>
          </span>
        </.form>
      </nav>

      <footer class="sidebar-footer">
        <Layouts.account_control current_user={@current_user} context={:row} />
      </footer>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :target_message_id, :any, default: nil
  attr :dot_state, :string, required: true
  attr :title, :string, required: true
  attr :meta, :string, required: true
  attr :rest, :global

  # Devin's two-line variant on the same __menu-item base: a bounded title line
  # over a text-12 muted meta line, led by an 8px status dot that reinforces —
  # never replaces — the meta words. When the row has durable transcript
  # evidence, the stretched hit target is a plain fragment anchor to that
  # message's DOM id, so the browser scrolls the transcript natively; when it
  # has none, the row is stated rather than dressed up as a link.
  defp sidebar_status_row(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "sidebar-row",
        "sidebar-row--two-line",
        is_nil(@target_message_id) && "sidebar-row--static"
      ]}
      {@rest}
    >
      <a
        :if={@target_message_id}
        href={"#messages-#{@target_message_id}"}
        class="sidebar-row__hit"
        aria-label={"#{@title} — #{@meta}"}
      ></a>
      <span class="sidebar-row__content">
        <.status_indicator class="sidebar-row__dot" state={@dot_state} label={@meta} decorative />
        <span class="sidebar-row__lines">
          <span class="sidebar-row__title">{@title}</span>
          <span class="sidebar-row__meta">{@meta}</span>
        </span>
      </span>
    </div>
    """
  end

  # ── Sidebar section row projections ─────────────────────────────────────────
  # The dot vocabulary maps job lifecycle to the existing status hues: blue
  # for a running job, green for completed, gold for interrupted/budget
  # attention, red for failure (DESIGN.md).
  defp job_dot_state(%{status: "completed"}), do: "succeeded"
  defp job_dot_state(%{status: "failed"}), do: "failed"

  defp job_dot_state(%{status: status}) when status in ~w(interrupted budget_exhausted),
    do: "attention"

  defp job_dot_state(_job), do: "running"

  defp job_title(%{goal: goal}) when is_binary(goal) do
    excerpt = String.slice(goal, 0, 80)
    if excerpt == goal, do: goal, else: excerpt <> "…"
  end

  defp job_meta(%{status: "budget_exhausted"}), do: "Budget exhausted"
  defp job_meta(%{status: status}), do: String.capitalize(status)

  # ── Live delegation projection helpers ──────────────────────────────────────

  defp delegation_summary(delegation) do
    %{
      ref: delegation.ref,
      kind: delegation.kind,
      machine_name: delegation.machine_name,
      agent_id: delegation.agent_id,
      status: if(delegation.state == :terminal, do: delegation.status, else: "running")
    }
  end

  # The subject is data, not copy: the delegated agent's id when the
  # controller ran one, otherwise the request kind.
  defp delegation_subject(%{agent_id: agent_id}) when agent_id not in [nil, ""], do: agent_id
  defp delegation_subject(%{kind: kind}), do: kind

  # Controller statuses map onto the step-outcome vocabulary and its hues,
  # exactly as OpenAgents.Tools.ComputerAgent maps the durable outcome: anything
  # unrecognized is stated as failed, never hidden.
  defp delegation_indicator_state("running"), do: "running"
  defp delegation_indicator_state("completed"), do: "succeeded"
  defp delegation_indicator_state("refused"), do: "refused"
  defp delegation_indicator_state("unavailable"), do: "unavailable"
  defp delegation_indicator_state("cancelled"), do: "cancelled"
  defp delegation_indicator_state(_timeout_failed_or_unknown), do: "failed"

  defp delegation_status_word(status),
    do: status |> delegation_indicator_state() |> String.upcase()

  defp delegation_duration(milliseconds) when is_integer(milliseconds) and milliseconds >= 0,
    do: duration_label(div(milliseconds, 1000))

  defp delegation_duration(_unknown), do: nil

  defp duration_label(seconds) when seconds < 0, do: nil
  defp duration_label(seconds) when seconds < 60, do: "#{seconds}s"

  defp duration_label(seconds) when seconds < 3600,
    do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp duration_label(seconds), do: "#{div(seconds, 3600)}h #{seconds |> rem(3600) |> div(60)}m"

  # Below 768px the sidebar hides behind this slim row: wordmark, connection
  # state, and the menu button that reveals the sidebar as an overlay.
  defp mobile_header(assigns) do
    ~H"""
    <header class="mobile-header">
      <.button
        id="mobile-menu"
        variant={:ghost}
        size={:sm}
        class="mobile-menu-button"
        aria-label="Toggle sidebar"
        aria-expanded="false"
        aria-controls="sidebar"
      >
        <.icon name="menu" />
      </.button>
      <span class="brand-name">SARAH</span>
      <.connection_state id_prefix="mobile-connection" />
    </header>
    """
  end

  attr :id_prefix, :string, required: true

  # Connection state is driven by the LiveView socket through element-level
  # connect/disconnect bindings, not by a stylesheet class, so RECONNECTING is
  # real rather than decorative (DESIGN.md, Sarah shell). Rendered twice —
  # sidebar header and mobile header — so the ids take a prefix.
  defp connection_state(assigns) do
    ~H"""
    <span class="connection-state">
      <.status_indicator
        id={"#{@id_prefix}-indicator"}
        state="connected"
        label="Connection to Sarah"
        decorative
        phx-connected={JS.set_attribute({"data-state", "connected"})}
        phx-disconnected={JS.set_attribute({"data-state", "reconnecting"})}
      />
      <span
        id={"#{@id_prefix}-connected"}
        class="connection-label"
        phx-connected={JS.show()}
        phx-disconnected={JS.hide()}
      >
        CONNECTED
      </span>
      <span
        id={"#{@id_prefix}-reconnecting"}
        class="connection-label"
        hidden
        phx-connected={JS.hide()}
        phx-disconnected={JS.show()}
      >
        RECONNECTING
      </span>
    </span>
    """
  end

  attr :delegation, :map, default: nil
  attr :summaries, :list, required: true
  attr :collapsed, :boolean, default: false

  # The live delegation rail (issue #85): a slim ephemeral right rail shown
  # only while a computer delegation is in flight or recently finished. It is
  # a projection of the PubSub stream, never chrome and never authority — the
  # transcript's durable event header remains the record. One live panel at a
  # time; superseded and finished delegations collapse to summary lines. The
  # rolling log is owned by the .DelegationLog hook (phx-update="ignore"), so
  # chunk text never rides an assign.
  defp delegation_rail(assigns) do
    ~H"""
    <aside
      id="delegation-rail"
      class="delegation-rail"
      data-collapsed={to_string(@collapsed)}
      aria-label="Live delegation"
    >
      <header class="delegation-rail__header">
        <h2 class="delegation-rail__label">LIVE DELEGATION</h2>
        <.button
          id="delegation-rail-toggle"
          variant={:ghost}
          size={:sm}
          class="delegation-rail__toggle"
          aria-label="Toggle delegation panel"
          aria-expanded={to_string(!@collapsed)}
          aria-controls="delegation-rail"
          phx-click="toggle_delegation_rail"
        >
          <.icon name="sidebar-collapse-right" class="delegation-rail__glyph-collapse" />
          <.icon name="sidebar-open-right" class="delegation-rail__glyph-expand" />
        </.button>
      </header>

      <div class="delegation-rail__body">
        <div
          :if={@delegation && @delegation.state == :running}
          id="delegation-live"
          class="delegation-live"
          data-status="running"
        >
          <div class="delegation-live__header">
            <.status_indicator state="running" label="RUNNING" />
            <span class="delegation-live__machine">{@delegation.machine_name}</span>
            <span class="delegation-live__subject">{delegation_subject(@delegation)}</span>
            <time
              id={"delegation-elapsed-#{@delegation.ref}"}
              class="delegation-live__elapsed"
              datetime={DateTime.to_iso8601(@delegation.started_at)}
              data-started-at={DateTime.to_iso8601(@delegation.started_at)}
              phx-hook=".DelegationClock"
              phx-update="ignore"
            ></time>
            <.button
              id="cancel-delegation"
              variant={:ghost}
              size={:xs}
              class="delegation-live__cancel"
              aria-label="Cancel delegation"
              phx-click="cancel_delegation"
            >
              <.icon name="stop" />
            </.button>
          </div>
          <div
            id={"delegation-log-rail-#{@delegation.ref}"}
            class="delegation-log"
            data-ref={@delegation.ref}
            phx-hook=".DelegationLog"
            phx-update="ignore"
          >
          </div>
          <.badge :if={@delegation.truncated?} variant={:dim} class="delegation-truncated">
            TRUNCATED
          </.badge>
        </div>

        <.delegation_summary_row
          :if={@delegation && @delegation.state == :terminal}
          id="delegation-terminal"
          delegation={@delegation}
        >
          <.button
            id="delegation-dismiss"
            variant={:ghost}
            size={:xs}
            class="delegation-summary__dismiss"
            aria-label="Dismiss"
            phx-click="dismiss_delegation"
          >
            <.icon name="x" />
          </.button>
        </.delegation_summary_row>

        <.delegation_summary_row
          :for={summary <- @summaries}
          id={"delegation-summary-#{summary.ref}"}
          delegation={summary}
          class="delegation-summary--superseded"
        />
      </div>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :delegation, :map, required: true
  attr :class, :any, default: nil
  slot :inner_block

  # A finished (or superseded) delegation as one bounded summary line: status
  # dot reinforcing the status word, machine and subject, then stop reason and
  # duration when the terminal carried them.
  defp delegation_summary_row(assigns) do
    ~H"""
    <div
      id={@id}
      class={["delegation-summary", @class]}
      data-status={delegation_indicator_state(@delegation.status)}
    >
      <.status_indicator
        class="delegation-summary__dot"
        state={delegation_indicator_state(@delegation.status)}
        label={delegation_status_word(@delegation.status)}
        decorative
      />
      <span class="delegation-summary__lines">
        <span class="delegation-summary__title">
          {@delegation.machine_name} · {delegation_subject(@delegation)}
        </span>
        <span class="delegation-summary__meta">
          {delegation_status_word(@delegation.status)}<span :if={
            Map.get(@delegation, :stop_reason) not in [nil, ""]
          }> · {@delegation.stop_reason}</span><span :if={
            duration = delegation_duration(Map.get(@delegation, :duration_ms))
          }> · {duration}</span>
        </span>
      </span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :delegation, :map, required: true

  # Narrow-viewport variant of the same projection: an expandable section on
  # the E1 event-header pattern at the transcript tail, with the live log in
  # the expansion. The stylesheet hides it at the desktop breakpoint, where
  # the rail takes over.
  defp delegation_inline(assigns) do
    ~H"""
    <section id="delegation-inline" class="delegation-inline" aria-label="Live delegation">
      <.event_header
        id="delegation-inline-header"
        status={delegation_indicator_state(@delegation.status)}
        title={"#{@delegation.machine_name} · #{delegation_subject(@delegation)}"}
        status_note={
          if(@delegation.state == :terminal, do: delegation_status_word(@delegation.status))
        }
        timestamp={@delegation.started_at}
      >
        <div class="delegation-inline__details">
          <div
            :if={@delegation.state == :running}
            id={"delegation-log-inline-#{@delegation.ref}"}
            class="delegation-log"
            data-ref={@delegation.ref}
            phx-hook=".DelegationLog"
            phx-update="ignore"
          >
          </div>
          <.button
            :if={@delegation.state == :running}
            id="cancel-delegation-inline"
            variant={:ghost}
            size={:xs}
            aria-label="Cancel delegation"
            phx-click="cancel_delegation"
          >
            <.icon name="stop" />
          </.button>
          <.badge :if={@delegation.truncated?} variant={:dim} class="delegation-truncated">
            TRUNCATED
          </.badge>
          <p :if={@delegation.state == :terminal} class="delegation-inline__outcome">
            {delegation_status_word(@delegation.status)}<span :if={
              @delegation.stop_reason not in [nil, ""]
            }> · {@delegation.stop_reason}</span><span :if={
              duration = delegation_duration(@delegation.duration_ms)
            }> · {duration}</span>
          </p>
          <.button
            :if={@delegation.state == :terminal}
            id="delegation-inline-dismiss"
            variant={:ghost}
            size={:xs}
            class="delegation-summary__dismiss"
            aria-label="Dismiss"
            phx-click="dismiss_delegation"
          >
            <.icon name="x" />
          </.button>
        </div>
      </.event_header>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :activity, :map, required: true

  # One durable tool step as an event header: the collapsed title says what
  # actually ran, and the expansion carries the bounded durable details —
  # including the executor disclosure, which lives here now rather than on
  # every collapsed row.
  defp activity_event(assigns) do
    ~H"""
    <.event_header
      id={@id}
      status={@activity.status}
      title={ToolActivity.title(@activity)}
      title_attribute={ToolActivity.title_attribute(@activity)}
      status_note={ToolActivity.status_note(@activity)}
      timestamp={ToolActivity.timestamp(@activity)}
    >
      <dl class="event-detail">
        <div :if={arguments = ToolActivity.arguments_pretty(@activity)}>
          <dt>ARGUMENTS</dt>
          <dd><pre>{arguments}</pre></dd>
        </div>
        <div :if={result = ToolActivity.payload_pretty(Map.get(@activity, :result))}>
          <dt>RESULT</dt>
          <dd><pre>{result}</pre></dd>
        </div>
        <div :if={error = ToolActivity.payload_pretty(Map.get(@activity, :error))}>
          <dt>ERROR</dt>
          <dd><pre>{error}</pre></dd>
        </div>
        <div :if={detail = ToolActivity.executor_detail(@activity)}>
          <dt>EXECUTOR</dt>
          <dd>
            <span :if={Map.get(@activity, :executor_id)} class="event-detail__executor-id">
              {@activity.executor_id}
            </span>
            {detail}
          </dd>
        </div>
        <div>
          <dt>STATUS</dt>
          <dd>{@activity.status}</dd>
        </div>
        <div :if={timeline = ToolActivity.timeline(@activity)}>
          <dt>TIMELINE</dt>
          <dd>{timeline}</dd>
        </div>
      </dl>
    </.event_header>
    """
  end

  attr :id, :string, required: true
  attr :message, :map, required: true
  attr :paced_items, :any, required: true
  attr :activity, :list, default: []
  attr :rollup, :map, default: nil

  # The transcript's asymmetry carries the roles (DESIGN.md, Message row): a
  # person's message is a right-aligned tinted bubble, Sarah's is bare
  # full-measure prose. Role labels and avatars retired with it; provenance
  # that means something — VOICE TRANSCRIPT / INTERRUPTED, the rare SYSTEM
  # row — keeps its label.
  defp message_row(assigns) do
    ~H"""
    <article
      id={@id}
      class={[
        "message-row",
        "message-row--#{@message.role}",
        @message.work_job_id && "message-row--report"
      ]}
      data-status={@message.status}
      data-modality={@message.modality}
    >
      <%!-- Floating hover toolbar: copy, copy-link, and the inline timestamp —
            the timestamps' first home in the transcript. Hover/focus-within
            reveals it; touch keeps it visible (Phase D grammar). --%>
      <div class="message-toolbar" role="toolbar" aria-label="Message actions">
        <time
          :if={@message.inserted_at}
          id={"#{@id}-time"}
          class="message-toolbar__time"
          datetime={DateTime.to_iso8601(@message.inserted_at)}
          phx-hook=".LocalTime"
        >
          {Calendar.strftime(@message.inserted_at, "%H:%M")}
        </time>
        <.button
          id={"#{@id}-copy"}
          variant={:ghost}
          size={:xs}
          class="message-toolbar__button"
          aria-label="Copy message"
          data-copy-kind="message"
        >
          <.icon name="copy" />
        </.button>
        <.button
          id={"#{@id}-copy-link"}
          variant={:ghost}
          size={:xs}
          class="message-toolbar__button"
          aria-label="Copy message link"
          data-copy-kind="link"
        >
          <.icon name="link" />
        </.button>
      </div>
      <div class="message-body">
        <.badge
          :if={@message.role not in ["assistant", "user"]}
          variant={:dim}
          class="message-provenance"
        >
          {role_label(@message.role)}
        </.badge>
        <section
          :if={@activity != []}
          id={"tool-activity-#{@id}"}
          class="tool-activity"
          role="status"
          aria-live="polite"
          aria-atomic="false"
          aria-label="Sarah activity"
        >
          <.activity_event
            :for={activity <- @activity}
            id={"tool-activity-step-#{activity.id}"}
            activity={activity}
          />
        </section>
        <.badge :if={@message.modality == "voice"} variant={:dim} class="message-provenance">
          VOICE TRANSCRIPT{if @message.interrupted, do: " / INTERRUPTED", else: ""}
        </.badge>
        <%!-- A deep-work report renders as a rollup header: how long the job
              worked and how its steps ended, expanding to the report itself. --%>
        <.event_header
          :if={@rollup}
          id={"job-rollup-#{@id}"}
          status={rollup_status(@rollup)}
          title={rollup_title(@rollup)}
          status_note={rollup_status_note(@rollup)}
          timestamp={@rollup.completed_at}
          class="job-rollup"
        >
          <:chips>
            <.badge :if={@rollup.succeeded_count > 0} variant={:success}>
              {@rollup.succeeded_count} SUCCEEDED
            </.badge>
            <.badge :if={@rollup.refused_count > 0} variant={:warning}>
              {@rollup.refused_count} REFUSED
            </.badge>
          </:chips>
          <div :if={@message.content != ""} class="message-content message-markdown">
            {OpenAgents.Markdown.to_html(@message.content, streaming: @message.status == "streaming")}
          </div>
        </.event_header>
        <div
          :if={
            !@rollup and @message.content != "" and
              not paced_live_transcript?(@message, @paced_items) and
              markdown?(@message)
          }
          class="message-content message-markdown"
        >
          {OpenAgents.Markdown.to_html(@message.content, streaming: @message.status == "streaming")}
        </div>
        <p
          :if={
            !@rollup and @message.content != "" and
              not paced_live_transcript?(@message, @paced_items) and
              not markdown?(@message)
          }
          class={["message-content", @message.role == "user" && "message-bubble"]}
          phx-no-format
        >{@message.content}</p>
        <p
          :if={@message.content != "" and paced_live_transcript?(@message, @paced_items)}
          class={["message-content", @message.role == "user" && "message-bubble"]}
          id={"#{@id}-paced"}
          phx-hook="PacedTranscript"
          phx-update="ignore"
          data-content={@message.content}
          data-item-id={@message.provider_item_id}
        >
        </p>
        <.badge
          :if={label = status_label(@message.status)}
          variant={message_status_variant(@message.status)}
          class="message-status"
        >
          <.status_indicator
            :if={@message.status == "streaming"}
            state="streaming"
            label={label}
            decorative
          />
          {label}
        </.badge>
      </div>
    </article>
    """
  end

  attr :form, :any, required: true
  attr :composer_error, :any, default: nil
  attr :active_turn, :map, default: nil
  attr :message_queue, :list, required: true
  attr :voice_enabled?, :boolean, required: true

  defp composer_stack(assigns) do
    ~H"""
    <ul
      :if={@message_queue != []}
      id="message-queue"
      class="message-queue"
      aria-label="Queued messages"
    >
      <li :for={item <- @message_queue} id={"queued-#{item.id}"} class="message-queue__item">
        <span class="message-queue__label">QUEUED</span>
        <span class="message-queue__text">{item.content}</span>
        <.button
          variant={:ghost}
          size={:xs}
          class="message-queue__dismiss"
          aria-label="Remove queued message"
          phx-click="dequeue_message"
          phx-value-id={item.id}
        >
          <.icon name="x" />
        </.button>
      </li>
    </ul>

    <.form for={@form} id="message-form" class="composer" phx-submit="send_message">
      <div class="composer-card">
        <.alert
          :if={@composer_error}
          id="composer-error"
          variant={:danger}
          appearance={:row}
          label="ATTENTION"
          class="composer-eyebrow"
        >
          <p>{@composer_error}</p>
        </.alert>

        <div class="composer-grid">
          <.textarea
            id={@form[:message].id}
            name={@form[:message].name}
            value={@form[:message].value}
            class="composer-input"
            placeholder="Message Sarah"
            aria-label="Message Sarah"
            rows="1"
            maxlength="8000"
            autocomplete="off"
            aria-describedby={if @composer_error, do: "composer-error"}
            phx-mounted={JS.focus()}
            phx-hook=".Composer"
          />
          <div class="composer-trailing">
            <.voice_session_buttons :if={@voice_enabled?} active_turn={@active_turn} />
            <.button
              :if={@active_turn}
              id="cancel-turn"
              variant={:ghost}
              class="send-action send-action--stop"
              aria-label="Stop response"
              phx-click="cancel_turn"
            >
              <.icon name="stop" />
            </.button>
            <.button
              id="send-message"
              type="submit"
              class="send-action"
              aria-label={if @active_turn, do: "Queue message", else: "Send"}
            >
              <.icon name="arrow-up" />
            </.button>
          </div>
        </div>
      </div>
    </.form>
    """
  end

  defp voice_status(assigns) do
    ~H"""
    <p id="voice-status" class="visually-hidden" role="status" aria-live="polite" aria-atomic="true">
      VOICE READY
    </p>
    <span class="visually-hidden">
      <.status_indicator id="voice-indicator" state="idle" label="Voice" decorative />
    </span>
    <span id="voice-recording-indicator" class="visually-hidden" hidden>
      RECORDING
    </span>
    """
  end

  attr :active_turn, :map, default: nil

  defp voice_session_buttons(assigns) do
    ~H"""
    <.button
      id="voice-start"
      type="button"
      variant={:ghost}
      class="send-action send-action--voice"
      disabled={@active_turn != nil}
      aria-label="Start voice"
    >
      <.icon name="mic" />
    </.button>
    <.button
      id="voice-mute"
      type="button"
      variant={:ghost}
      class="send-action send-action--voice"
      hidden
      disabled
      aria-label="Mute microphone"
      aria-pressed="false"
    >
      <.icon name="mic-off" />
    </.button>
    <.button
      id="voice-interrupt"
      type="button"
      variant={:ghost}
      class="send-action send-action--voice"
      hidden
      disabled
      aria-label="Interrupt Sarah"
    >
      <.icon name="stop" />
    </.button>
    <.button
      id="voice-unlock"
      type="button"
      variant={:ghost}
      class="send-action send-action--voice"
      hidden
      aria-label="Enable audio"
    >
      <.icon name="sound-on-read-out-loud-speaker" />
    </.button>
    <.button
      id="voice-end"
      type="button"
      variant={:ghost}
      class="send-action send-action--voice send-action--voice-end"
      hidden
      disabled
      aria-label="End voice"
    >
      <.icon name="x-circle" />
    </.button>
    """
  end

  attr :memory_records, :list, required: true
  attr :memory_status, :any, default: nil
  attr :pending_memory_action, :any, default: nil
  attr :privacy_delete_form, :any, required: true
  attr :recording_config, :map, required: true

  defp memory_manager(assigns) do
    ~H"""
    <section id="memory-manager" class="memory-manager" aria-labelledby="memory-heading">
      <header class="memory-header">
        <div>
          <h1 id="memory-heading">Memory in your account</h1>
          <p>
            These records follow your authenticated Sarah account across browsers. Logging
            out removes this browser's access; server records follow the documented
            retention lifecycle.
          </p>
        </div>
        <div class="memory-header__actions">
          <.text_button id="export-all-data" href="/data/export" download>
            <.icon name="download" /> Export ALL DATA
          </.text_button>
          <.text_button id="export-memory" href="/memory/export" download>
            <.icon name="download" /> Export Memory ONLY
          </.text_button>
          <.text_button
            id="forget-all-memory"
            tone={:danger}
            phx-click="request_memory_forget"
            phx-value-kind="all"
            disabled={not Enum.any?(@memory_records, &(&1["status"] == "active"))}
          >
            <.icon name="trash" /> FORGET ALL ACTIVE
          </.text_button>
        </div>
      </header>

      <.alert
        :if={@memory_status}
        id="memory-status"
        appearance={:row}
        variant={memory_status_variant(@memory_status)}
      >
        {elem(@memory_status, 1)}
      </.alert>

      <.card
        :if={@pending_memory_action}
        id="memory-confirmation"
        variant={:danger}
        aria-labelledby="memory-confirmation-heading"
      >
        <header>
          <h2 id="memory-confirmation-heading">Confirm destructive action</h2>
          <p>{@pending_memory_action.label}</p>
          <p>Future snapshots will no longer include the affected active records.</p>
        </header>
        <footer class="memory-confirmation__actions">
          <.button
            id="confirm-memory-forget"
            size={:sm}
            variant={:destructive}
            phx-click="confirm_memory_forget"
          >
            <.icon name="trash" /> CONFIRM FORGET
          </.button>
          <.button
            id="cancel-memory-action"
            size={:sm}
            variant={:secondary}
            phx-click="cancel_memory_action"
          >
            KEEP Memory
          </.button>
        </footer>
      </.card>

      <.empty :if={@memory_records == []} id="memory-empty" title="No profile memories yet">
        Sarah automatically remembers lasting facts you share in conversation, like
        your name, role, projects, and preferences. Memory belongs to your Sarah account.
      </.empty>

      <div :if={@memory_records != []} id="memory-records" class="memory-records">
        <.memory_record :for={record <- @memory_records} record={record} />
      </div>

      <.card
        id="privacy-controls"
        variant={:danger}
        class="memory-confirmation"
        aria-labelledby="privacy-heading"
      >
        <header>
          <h2 id="privacy-heading">Voice and deletion</h2>
          <p>
            Final and interrupted transcripts remain in this account's conversation.
            Detailed operational voice evidence is purged after 90 days. Export before
            deleting if you want a copy.
          </p>
          <%!-- The recording sentence appears only while recording is on, so this
                surface and the voice control row can never disagree about it. --%>
          <p :if={@recording_config.enabled?} id="privacy-recording">
            Call audio is recorded, stored encrypted, and readable by a Sarah operator.
            It is deleted {@recording_config.retention_days} days after a call ends, and
            deleting your data removes it immediately.
          </p>
        </header>
        <footer>
          <.form
            for={@privacy_delete_form}
            id="delete-data-form"
            action="/data"
            method="delete"
            class="privacy-delete-form"
          >
            <.field>
              <.label for={@privacy_delete_form[:confirmation].id}>
                Type DELETE MY SARAH DATA to delete this account's Sarah conversation,
                transcripts, memory, receipts, and voice records. Minimal GitHub identity and
                access-status data remains so bans and access controls cannot be bypassed.
              </.label>
              <div class="control-row">
                <.input
                  id={@privacy_delete_form[:confirmation].id}
                  name={@privacy_delete_form[:confirmation].name}
                  value={@privacy_delete_form[:confirmation].value}
                  type="text"
                  class="control-row__input"
                  autocomplete="off"
                  required
                />
                <.button id="delete-all-data" type="submit" size={:sm} variant={:destructive}>
                  <.icon name="trash" /> DELETE ALL DATA
                </.button>
              </div>
            </.field>
          </.form>
        </footer>
      </.card>
    </section>
    """
  end

  attr :record, :map, required: true

  defp memory_record(assigns) do
    ~H"""
    <.card
      id={"memory-record-#{@record["id"]}"}
      state={@record["status"]}
      frame={:corners}
      data-status={@record["status"]}
    >
      <div class="memory-record__meta">
        <.badge>{String.upcase(@record["category"])}</.badge>
        <.badge variant={memory_badge_variant(@record["status"])}>
          {String.upcase(@record["status"])}
        </.badge>
        <.badge>
          <time datetime={@record["inserted_at"]}>{memory_date(@record["inserted_at"])}</time>
        </.badge>
      </div>

      <p class="memory-record__claim">{@record["claim"] || "WITHHELD BY PRIVACY POLICY"}</p>

      <dl class="memory-record__sources">
        <div>
          <dt>Scope</dt>
          <dd>This account</dd>
        </div>
        <div>
          <dt>Generation</dt>
          <dd>{@record["generation"]}</dd>
        </div>
        <div>
          <dt>Sources</dt>
          <dd>
            <span :if={@record["sources"] == []}>Explicit account-owner assertion</span>
            <span :for={source <- @record["sources"]}>
              {source["kind"]} / {memory_date(source["observed_at"])}
            </span>
          </dd>
        </div>
      </dl>

      <div :if={@record["status"] == "active"} class="memory-record__controls">
        <form phx-submit="correct_memory" class="memory-correction">
          <input type="hidden" name="record_id" value={@record["id"]} />
          <.field>
            <.label for={"memory-claim-#{@record["id"]}"}>Correct this memory</.label>
            <div class="control-row">
              <.input
                id={"memory-claim-#{@record["id"]}"}
                name="claim"
                type="text"
                value={@record["claim"]}
                class="control-row__input"
                maxlength="500"
                required
              />
              <.button type="submit" size={:sm} variant={:secondary}>SAVE CORRECTION</.button>
            </div>
          </.field>
        </form>
        <div class="memory-record__destructive">
          <.text_button
            id={"forget-record-#{@record["id"]}"}
            tone={:danger}
            phx-click="request_memory_forget"
            phx-value-kind="record"
            phx-value-id={@record["id"]}
          >
            <.icon name="trash" /> FORGET RECORD
          </.text_button>
          <.text_button
            id={"forget-category-#{@record["id"]}"}
            tone={:danger}
            phx-click="request_memory_forget"
            phx-value-kind="category"
            phx-value-category={@record["category"]}
          >
            <.icon name="trash" /> FORGET {String.upcase(@record["category"])} CATEGORY
          </.text_button>
        </div>
      </div>
    </.card>
    """
  end
end
