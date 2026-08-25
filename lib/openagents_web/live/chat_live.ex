defmodule OpenAgentsWeb.ChatLive do
  use OpenAgentsWeb, :live_view

  alias OpenAgents.{
    Analytics,
    Conversations,
    DataRights,
    ProfileMemory,
    Turns,
    Voice,
    VoiceSessions
  }

  alias OpenAgents.Analytics.Chat, as: ChatAnalytics
  alias OpenAgents.Conversations.Message
  alias OpenAgents.Voice.Config, as: VoiceConfig
  alias OpenAgents.Voice.Recordings
  alias OpenAgentsWeb.ToolActivity
  alias OpenAgentsWeb.UI

  # The chat surface is composed from the ported AI Elements, not from bespoke
  # chat CSS: the transcript is `conversation`/`message`, the composer is
  # `prompt_input`, queued messages are `queue`, and a tool call is `tool`.
  # Imported rather than aliased so the call sites still read as AI Elements.
  import OpenAgentsWeb.AI.Conversation,
    only: [
      conversation: 1,
      conversation_content: 1,
      message: 1,
      message_content: 1,
      message_actions: 1,
      message_action: 1,
      shimmer: 1
    ]

  import OpenAgentsWeb.AI.PromptInput,
    only: [
      prompt_input: 1,
      prompt_input_textarea: 1,
      prompt_input_header: 1,
      prompt_input_toolbar: 1,
      prompt_input_tools: 1,
      prompt_input_button: 1,
      prompt_input_submit: 1,
      queue: 1,
      queue_section: 1,
      queue_section_trigger: 1,
      queue_section_label: 1,
      queue_section_content: 1,
      queue_list: 1,
      queue_item: 1,
      queue_item_indicator: 1,
      queue_item_content: 1,
      queue_item_actions: 1,
      queue_item_action: 1
    ]

  import OpenAgentsWeb.AI.Reasoning, only: [tool: 1, tool_header: 1, tool_content: 1]

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

      Analytics.capture("chat_opened", Analytics.distinct_id(current_user))
    end

    socket =
      socket
      |> assign(:page_title, "Sarah")
      |> assign(:reset_enabled?, DataRights.reset_enabled?())
      |> assign(:conversation, conversation)
      |> assign(:has_older?, has_older?)
      |> assign(:oldest_message_id, first_id(messages))
      |> assign(:active_turn, active_turn)
      |> assign(:message_queue, [])
      |> assign(:stream_chunk_captured_at, nil)
      |> assign(:voice_enabled?, voice_config.enabled?)
      |> assign(:recording_config, Recordings.config())
      |> assign(:voice_session, voice_session)
      |> assign(:tool_activity, tool_activity(active_turn, voice_session))
      |> assign(:message_activity, message_activity(messages))
      |> assign(:composer_error, nil)
      |> assign(:form, composer_form())
      |> assign(:live_voice_items, MapSet.new())
      |> assign(:paced_voice_items, MapSet.new())
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

    {:noreply, socket}
  end

  @impl true
  def handle_info({:message_updated, message}, socket) do
    {:noreply,
     socket
     |> capture_assistant_message(message)
     |> clear_live_voice_item(message.provider_item_id)
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
      capture_turn_completed(turn, socket)
      capture_turn_failed(turn, socket)

      # The active turn ended: clear it, surface any error, and immediately start
      # the next queued message so a stacked run continues without the owner
      # re-sending.
      socket
      |> assign(:active_turn, nil)
      |> assign(:tool_activity, [])
      |> assign(:composer_error, turn.error_message)
      |> assign(:stream_chunk_captured_at, nil)
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

    capture_voice_lifecycle(socket, voice_session)

    {:noreply,
     socket
     |> assign(:voice_session, voice_session)
     |> assign(:tool_activity, activity)}
  end

  def handle_info({:voice_session_updated, _other_session}, socket), do: {:noreply, socket}

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

        Analytics.capture(
          "chat_message_sent",
          Analytics.distinct_id(socket.assigns.current_user),
          %{"length_bucket" => length_bucket(content)}
        )

        socket =
          socket
          |> stream_insert(:messages, records.user_message)
          |> stream_insert(:messages, records.assistant_message)
          |> assign(:active_turn, records.turn)
          |> assign(:tool_activity, [])
          |> assign(:composer_error, nil)
          |> assign(:form, composer_form())
          |> grant_agent_surfaces()
          |> push_event("composer:clear", %{})
          |> push_event("chat:scroll-bottom", %{})

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :composer_error, error_message(reason))}
    end
  end

  # Writing to her is the act that earns the sidebar section. The scope is
  # resolved once at mount, so without this the person who just sent their
  # first message would not see the section until their next page load.
  defp grant_agent_surfaces(
         %{assigns: %{current_scope: %{agent_surfaces?: false} = scope}} = socket
       ) do
    Phoenix.Component.assign(socket, :current_scope, %{scope | agent_surfaces?: true})
  end

  defp grant_agent_surfaces(socket), do: socket

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

        ChatAnalytics.message_queued(
          Analytics.distinct_id(socket.assigns.current_user),
          %{
            "length_bucket" => length_bucket(trimmed),
            "queue_depth" => length(socket.assigns.message_queue) + 1,
            "conversation_id" => socket.assigns.conversation.id
          }
        )

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
  # what she said, and so a reload rebuilds it from PostgreSQL. Voice steps are
  # merged in from their response receipts: a spoken tool call carries the same
  # authority as a typed one, so it stays in the ordered stream after the call
  # ends instead of vanishing with the live panel.
  defp message_activity(messages) do
    assistant_message_ids =
      messages
      |> Enum.filter(&(&1.role == "assistant"))
      |> Enum.map(& &1.id)

    text = Conversations.list_tool_step_activity_by_message(assistant_message_ids)
    voice = Voice.list_tool_step_activity_by_message(assistant_message_ids)

    Map.merge(text, voice, fn _message_id, text_steps, voice_steps ->
      Enum.sort_by(text_steps ++ voice_steps, & &1.sequence)
    end)
  end

  defp first_id([message | _messages]), do: message.id
  defp first_id([]), do: nil

  # Terminal turn broadcasts arrive once per turn; the duration comes from the
  # turn's own lifecycle timestamps, so no extra query is needed.
  defp capture_turn_completed(turn, socket) do
    duration_ms =
      if is_nil(turn.started_at) or is_nil(turn.completed_at),
        do: nil,
        else: DateTime.diff(turn.completed_at, turn.started_at, :millisecond)

    Analytics.capture(
      "chat_turn_completed",
      Analytics.distinct_id(socket.assigns.current_user),
      %{
        "outcome" => turn.status,
        "duration_ms" => duration_ms
      }
    )
  end

  # A failed or cancelled turn is reported beside the completion event so a
  # failure rate can be read from one event instead of a property filter.
  defp capture_turn_failed(%{status: "completed"}, _socket), do: :ok

  defp capture_turn_failed(turn, socket) do
    ChatAnalytics.turn_failed(
      Analytics.distinct_id(socket.assigns.current_user),
      %{
        "reason" => turn.error_code || turn.status,
        "outcome" => turn.status,
        "conversation_id" => turn.conversation_id,
        "turn_id" => turn.id
      }
    )
  end

  # Every assistant delta re-broadcasts the message, which makes this both the
  # stream-chunk signal and, at the terminal status, the one place an assistant
  # message is known to have reached the reader. Chunks are throttled inside
  # `OpenAgents.Analytics.Chat`; the throttle rides in an assign so it resets
  # with each turn.
  defp capture_assistant_message(
         socket,
         %Message{role: "assistant", status: "streaming"} = message
       ) do
    captured_at =
      ChatAnalytics.stream_chunk(
        Analytics.distinct_id(socket.assigns.current_user),
        socket.assigns.stream_chunk_captured_at,
        %{
          "conversation_id" => message.conversation_id,
          "modality" => message.modality
        }
      )

    assign(socket, :stream_chunk_captured_at, captured_at)
  end

  defp capture_assistant_message(
         socket,
         %Message{role: "assistant", status: "complete"} = message
       ) do
    ChatAnalytics.message_received(
      Analytics.distinct_id(socket.assigns.current_user),
      %{
        "length_bucket" => length_bucket(message.content || ""),
        "modality" => message.modality,
        "conversation_id" => message.conversation_id
      }
    )

    socket
  end

  defp capture_assistant_message(socket, _message), do: socket

  # Status broadcasts repeat through a call's life, so the transitions are read
  # against the session already in the assign: absent to live starts a call,
  # live to terminal ends one.
  defp capture_voice_lifecycle(socket, voice_session) do
    previous = socket.assigns.voice_session
    distinct_id = Analytics.distinct_id(socket.assigns.current_user)
    terminal? = voice_session.status in ~w(ended failed)

    cond do
      is_nil(previous) and not terminal? ->
        ChatAnalytics.voice_started(distinct_id, %{
          "conversation_id" => voice_session.conversation_id
        })

      not is_nil(previous) and previous.status not in ~w(ended failed) and terminal? ->
        ChatAnalytics.voice_ended(distinct_id, %{
          "conversation_id" => voice_session.conversation_id,
          "outcome" => voice_session.status,
          "duration_ms" => voice_duration_ms(voice_session)
        })

      true ->
        :ok
    end
  end

  defp voice_duration_ms(%{
         started_at: %DateTime{} = started_at,
         ended_at: %DateTime{} = ended_at
       }),
       do: DateTime.diff(ended_at, started_at, :millisecond)

  defp voice_duration_ms(_voice_session), do: nil

  defp length_bucket(content), do: ChatAnalytics.length_bucket(content)

  defp tool_activity(nil, nil), do: []

  defp tool_activity(turn, _voice_session) when not is_nil(turn),
    do: Conversations.list_tool_step_activity(turn)

  defp tool_activity(nil, voice_session), do: Voice.list_tool_step_activity(voice_session)

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

  defp message_status_variant("streaming"), do: :info
  defp message_status_variant(_status), do: :warning

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      title="Chat"
      current_scope={@current_scope}
      flush
    >
      <%!-- Export is the conversation's action, so it belongs beside the
      conversation's name rather than as a permanent sidebar row competing with
      the places you can go. --%>
      <:title_menu>
        <.button
          id="chat-actions-trigger"
          variant={:ghost}
          size={:sm}
          class="chat-actions-trigger"
          popovertarget="chat-actions-menu"
          popovertargetaction="toggle"
          aria-label="Conversation actions"
        >
          <.icon name="chevron-down" />
        </.button>

        <UI.menu id="chat-actions-menu" label="Conversation actions">
          <a id="export-atif" href="/data/export/atif" download role="menuitem" class="menu__item">
            <.icon name="download" /> Export JSON (ATIF)
          </a>
        </UI.menu>
      </:title_menu>

      <:sidebar_extra>
        <.chat_sidebar_rows current_user={@current_user} reset_enabled?={@reset_enabled?} />
      </:sidebar_extra>

      <div id="openagents-app" class="chat-shell">
        <main class="app-main">
          <%!-- `conversation/1` owns the scroller and the return-to-newest
                control; this wrapper exists only to carry `.TranscriptScroll`,
                which owns the three things the AI Elements hook does not: the
                copied-link anchor, scroll preservation when older messages are
                prepended, and the server's own scroll-to-bottom event. --%>
          <div id="transcript" class="transcript" phx-hook=".TranscriptScroll">
            <.conversation id="conversation" aria-label="Conversation transcript">
              <.conversation_content id="conversation-content" class="message-list">
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

                <%!-- `display: contents`, so the stream container the hook and the
                      tests need does not become a second box between the turns and
                      the column that spaces them. --%>
                <div
                  id="messages"
                  class="contents"
                  phx-update="stream"
                  phx-hook=".TranscriptActions"
                >
                  <.message_row
                    :for={{dom_id, message} <- @streams.messages}
                    id={dom_id}
                    message={message}
                    paced_items={@paced_voice_items}
                    activity={Map.get(@message_activity, message.id, [])}
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
              </.conversation_content>
            </.conversation>
          </div>

          <footer class="composer-region">
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
                recording_config={@recording_config}
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
              recording_config={@recording_config}
            />
          </footer>
        </main>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".TranscriptScroll">
        // Follows the AI Elements conversation's own `.StickToBottom`, which
        // owns pinning to the newest turn and the scroll-to-newest control.
        // What is left here is what that hook does not do: land on a copied
        // message link, hold the reader's place when older messages are
        // prepended above them, and honour the server's scroll-to-bottom event.
        export default {
          mounted() {
            this.preserveNextUpdate = false
            this.viewport = this.el.querySelector("[data-conversation-viewport]")
            // A copied message link lands here as /chat#<row id>: scroll the
            // row into view and flash it once. The flash animation is killed
            // by the global reduced-motion rule, so the mechanic stays
            // motion-safe.
            //
            // On the next frame, not now. This element is the conversation's
            // parent, so its hook mounts first, and the conversation's own
            // mount then pins the viewport to the newest turn — which would
            // scroll straight past the row the link named. Landing a frame
            // later both wins that race and moves the viewport off the bottom,
            // which unpins the other hook so it stays where the reader was
            // sent.
            const anchor = window.location.hash.slice(1)
            const target = anchor && document.getElementById(anchor)
            if (target && this.el.contains(target)) {
              requestAnimationFrame(() => {
                target.scrollIntoView({ block: "center" })
                target.setAttribute("data-flash", "")
                setTimeout(() => target.removeAttribute("data-flash"), 1600)
              })
            }
            this.handleEvent("chat:scroll-bottom", () => this.scrollToBottom())
            this.handleEvent("history:prepend", () => { this.preserveNextUpdate = true })
          },
          beforeUpdate() {
            if (!this.viewport) return
            this.previousHeight = this.viewport.scrollHeight
            this.previousTop = this.viewport.scrollTop
          },
          updated() {
            if (!this.viewport || !this.preserveNextUpdate) return
            this.viewport.scrollTop =
              this.previousTop + (this.viewport.scrollHeight - this.previousHeight)
            this.preserveNextUpdate = false
          },
          scrollToBottom() {
            if (this.viewport) this.viewport.scrollTop = this.viewport.scrollHeight
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
        // The AI Elements `.PromptInput` hook on the form owns auto-resize and
        // Enter-to-submit. What is left here is the pair of server events that
        // drive the control from the LiveView: focus it when a turn ends, and
        // empty it after LiveView has read the submitted form.
        export default {
          mounted() {
            this.handleEvent("composer:focus", () => this.el.focus())
            // LiveView reads FormData during the submit event. Clearing here
            // races that read and can send an empty message.
            this.handleEvent("composer:clear", () => this.clear())
          },
          clear() {
            this.el.value = ""
            // Hands the resize back to the form's hook rather than repeating it.
            this.el.dispatchEvent(new Event("input", { bubbles: true }))
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
  attr :reset_enabled?, :boolean, required: true

  # The conversation's own rows, contributed to the application sidebar. The
  # shared destinations live there directly; what is left here is the
  # conversation's data action. Rows are the stretched-anchor pattern: the hit
  # control owns the whole row and the accessible name, the visible content
  # beneath is pointer-transparent, and any future trailing control floats back
  # above it at its own z-index.
  defp chat_sidebar_rows(assigns) do
    ~H"""
    <%!-- Admin moved to the sidebar footer, where it is one row for an
    operator on every page rather than a row that only exists on chat. What
    stays here is the conversation's own data action. --%>
    <nav :if={@reset_enabled?} id="sidebar-admin" class="sidebar-nav" aria-label="Data">
      <.form
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
    """
  end

  attr :id, :string, required: true
  attr :activity, :map, required: true

  # One durable tool step as an AI Elements tool block: the summary says what
  # actually ran and states the step's real state as a word beside a status
  # badge, and the expansion carries the bounded durable details — including
  # the executor disclosure, which lives here rather than on every collapsed
  # row. `<details>` supplies the disclosure, so no script and no ARIA to keep
  # in sync; a stream re-insert collapses the row again, which is honest.
  defp activity_event(assigns) do
    ~H"""
    <.tool id={@id}>
      <.tool_header
        title={ToolActivity.title(@activity)}
        type="dynamic-tool"
        tool_name={@activity.tool_name}
        state={tool_state(@activity.status)}
      />
      <.tool_content id={"#{@id}-details"}>
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
      </.tool_content>
    </.tool>
    """
  end

  # The durable step statuses mapped onto the AI SDK tool-part states the
  # ported `tool_header/1` badge reads. Every terminal status that is not a
  # success or a refusal is an error state; the expansion still states the
  # exact word, so nothing is lost by the narrower vocabulary.
  defp tool_state("requested"), do: "input-streaming"
  defp tool_state("running"), do: "input-available"
  defp tool_state("succeeded"), do: "output-available"
  defp tool_state("refused"), do: "output-denied"
  defp tool_state(_failed_cancelled_unavailable_or_interrupted), do: "output-error"

  attr :id, :string, required: true
  attr :message, :map, required: true
  attr :paced_items, :any, required: true
  attr :activity, :list, default: []

  # The transcript's asymmetry carries the roles (DESIGN.md, Message row): a
  # person's message is a right-aligned tinted bubble, Sarah's is bare
  # full-measure prose. Both now come from AI Elements: `message/1` carries the
  # `is-user`/`is-assistant` marker and `message_content/1` reads it for the
  # bubble. Role labels and avatars retired with the asymmetry; provenance that
  # means something — VOICE TRANSCRIPT / INTERRUPTED, the rare SYSTEM row —
  # keeps its label.
  #
  # `items-end` on a person's row is the one thing the components do not
  # supply: `message/1` pushes the row to the right edge and
  # `message_content/1` pushes the bubble inside it, but the toolbar above the
  # bubble is the row's own child and would otherwise stay at the left.
  defp message_row(assigns) do
    # The four content branches are mutually exclusive, so the conditions are
    # derived once here rather than restated on each of them.
    paced? = paced_live_transcript?(assigns.message, assigns.paced_items)
    written? = assigns.message.content != ""

    assigns =
      assigns
      |> assign(:paced?, paced? and written?)
      |> assign(:prose?, written? and not paced? and markdown?(assigns.message))
      |> assign(:plain?, written? and not paced? and not markdown?(assigns.message))
      |> assign(:streaming?, assigns.message.status == "streaming")

    ~H"""
    <.message
      id={@id}
      from={@message.role}
      class={[
        "message-row",
        "message-row--#{@message.role}",
        @message.work_job_id && "message-row--report",
        @message.role == "user" && "items-end"
      ]}
      data-status={@message.status}
      data-modality={@message.modality}
    >
      <%!-- Floating hover toolbar: copy, copy-link, and the inline timestamp —
            the timestamps' first home in the transcript. Hover/focus-within
            reveals it; touch keeps it visible (Phase D grammar). --%>
      <.message_actions class="message-toolbar" role="toolbar" aria-label="Message actions">
        <time
          :if={@message.inserted_at}
          id={"#{@id}-time"}
          class="message-toolbar__time"
          datetime={DateTime.to_iso8601(@message.inserted_at)}
          phx-hook=".LocalTime"
        >
          {Calendar.strftime(@message.inserted_at, "%H:%M")}
        </time>
        <.message_action
          id={"#{@id}-copy"}
          label="Copy message"
          class="message-toolbar__button"
          data-copy-kind="message"
        >
          <.icon name="copy" />
        </.message_action>
        <.message_action
          id={"#{@id}-copy-link"}
          label="Copy message link"
          class="message-toolbar__button"
          data-copy-kind="link"
        >
          <.icon name="link" />
        </.message_action>
      </.message_actions>
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
      <.message_content
        :if={@prose?}
        class="message-content message-markdown"
        text={@message.content}
        streaming={@streaming?}
      />
      <.message_content :if={@plain?}>
        <p
          class="message-content"
          phx-no-format
        >{@message.content}</p>
      </.message_content>
      <.message_content :if={@paced?}>
        <p
          class="message-content"
          id={"#{@id}-paced"}
          phx-hook="PacedTranscript"
          phx-update="ignore"
          data-content={@message.content}
          data-item-id={@message.provider_item_id}
        >
        </p>
      </.message_content>
      <.badge
        :if={label = status_label(@message.status)}
        variant={message_status_variant(@message.status)}
        class="message-status"
      >
        <.status_indicator :if={@streaming?} state="streaming" label={label} decorative />
        <%!-- Text that is still arriving reads as still arriving: the band
              sweeps across the word while the turn runs, and settles into
              plain text the moment it stops. --%>
        <.shimmer :if={@streaming?} tag="span" text={label} />
        <span :if={!@streaming?}>{label}</span>
      </.badge>
    </.message>
    """
  end

  attr :form, :any, required: true
  attr :composer_error, :any, default: nil
  attr :active_turn, :map, default: nil
  attr :message_queue, :list, required: true
  attr :voice_enabled?, :boolean, required: true
  attr :recording_config, :map, required: true

  defp composer_stack(assigns) do
    ~H"""
    <%!-- Messages waiting on the running turn, as the AI Elements queue: one
          collapsible section stating how many are lined up, and a row each with
          the control that drops it before it runs. --%>
    <.queue :if={@message_queue != []} id="message-queue" class="message-queue">
      <.queue_section id="message-queue-section" aria-label="Queued messages">
        <.queue_section_trigger>
          <.queue_section_label label="QUEUED" count={length(@message_queue)} />
        </.queue_section_trigger>
        <.queue_section_content>
          <.queue_list>
            <.queue_item :for={item <- @message_queue} id={"queued-#{item.id}"}>
              <div class="flex items-start gap-2">
                <.queue_item_indicator />
                <.queue_item_content>{item.content}</.queue_item_content>
                <.queue_item_actions>
                  <.queue_item_action
                    label="Remove queued message"
                    phx-click="dequeue_message"
                    phx-value-id={item.id}
                  >
                    <.icon name="x" />
                  </.queue_item_action>
                </.queue_item_actions>
              </div>
            </.queue_item>
          </.queue_list>
        </.queue_section_content>
      </.queue_section>
    </.queue>

    <.prompt_input
      id="message-form"
      for={@form}
      class="composer"
      phx-submit="send_message"
    >
      <%!-- The error is the strip above the control, which is where the input
            group puts anything that belongs to the composer but is not the
            composer. --%>
      <.prompt_input_header :if={@composer_error}>
        <.alert
          id="composer-error"
          variant={:danger}
          appearance={:row}
          label="ATTENTION"
          class="composer-eyebrow"
        >
          <p>{@composer_error}</p>
        </.alert>
      </.prompt_input_header>

      <.prompt_input_textarea
        field={@form[:message]}
        placeholder="Message Sarah"
        aria-label="Message Sarah"
        rows="1"
        maxlength="8000"
        autocomplete="off"
        aria-describedby={if @composer_error, do: "composer-error"}
        phx-mounted={JS.focus()}
        phx-hook=".Composer"
      />

      <.prompt_input_toolbar>
        <%!-- Nothing sits at the leading edge of this composer yet — no
              attachments, no model select — so the controls are pushed to the
              trailing edge rather than an empty group being drawn opposite
              them. --%>
        <.prompt_input_tools class="ml-auto">
          <.voice_session_buttons
            :if={@voice_enabled?}
            active_turn={@active_turn}
            recording_config={@recording_config}
          />
          <%!-- Stop stays its own control rather than `on_stop` on the submit:
                a message sent while a turn runs queues, so send and stop are
                two live actions, not one control in two states. --%>
          <.prompt_input_button
            :if={@active_turn}
            id="cancel-turn"
            variant={:destructive}
            aria-label="Stop response"
            phx-click="cancel_turn"
          >
            <.icon name="stop" class="size-4" />
          </.prompt_input_button>
          <.prompt_input_submit
            id="send-message"
            status={if @active_turn, do: :submitted, else: :ready}
            label={if @active_turn, do: "Queue message", else: "Send"}
          />
        </.prompt_input_tools>
      </.prompt_input_toolbar>
    </.prompt_input>
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
  attr :recording_config, :map, required: true

  defp voice_session_buttons(assigns) do
    ~H"""
    <p :if={@recording_config.enabled?} id="voice-recording-disclosure">
      Call audio is recorded, stored encrypted, and readable by a Sarah operator.
      It is deleted {@recording_config.retention_days} days after a call ends, and
      deleting your data removes it immediately.
    </p>
    <.prompt_input_button
      id="voice-start"
      variant={:outline}
      disabled={@active_turn != nil}
      aria-label="Start voice"
    >
      <.icon name="mic" class="size-4" />
    </.prompt_input_button>
    <.prompt_input_button
      id="voice-mute"
      variant={:outline}
      hidden
      disabled
      aria-label="Mute microphone"
      aria-pressed="false"
    >
      <.icon name="mic-off" class="size-4" />
    </.prompt_input_button>
    <.prompt_input_button
      id="voice-interrupt"
      variant={:outline}
      hidden
      disabled
      aria-label="Interrupt Sarah"
    >
      <.icon name="stop" class="size-4" />
    </.prompt_input_button>
    <.prompt_input_button id="voice-unlock" variant={:outline} hidden aria-label="Enable audio">
      <.icon name="sound-on-read-out-loud-speaker" class="size-4" />
    </.prompt_input_button>
    <%!-- Ending a call is the one destructive control in the row, so it keeps
          the danger hue the retired `.send-action--voice-end` gave it. --%>
    <.prompt_input_button
      id="voice-end"
      variant={:outline}
      class="text-danger"
      hidden
      disabled
      aria-label="End voice"
    >
      <.icon name="x-circle" class="size-4" />
    </.prompt_input_button>
    """
  end
end
