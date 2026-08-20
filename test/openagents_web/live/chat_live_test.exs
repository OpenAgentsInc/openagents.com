defmodule OpenAgentsWeb.ChatLiveTest do
  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias OpenAgents.{Context.Composer, Conversations, ProfileMemory, Voice}
  alias OpenAgents.Conversations.{Message, Visitor}
  alias OpenAgents.Providers.Request

  test "the composer takes focus when the conversation opens", %{conn: conn} do
    conn = log_in_github_user(conn, "composer-focus-browser")
    {:ok, view, _html} = live(conn, ~p"/chat")

    # Declarative rather than a hook call, so it also fires when the composer
    # remounts - returning from the memory surface, for instance.
    assert has_element?(view, "#chat_message[phx-mounted]")
  end

  test "the composer error renders as the eyebrow inside the card", %{conn: conn} do
    conn = log_in_github_user(conn, "composer-eyebrow-browser")
    {:ok, view, _html} = live(conn, ~p"/chat")

    view
    |> form("#message-form", chat: %{message: "   "})
    |> render_submit()

    # The error is part of the card rather than a full-width band above the
    # form: same id, same aria-describedby wiring, now inside the form.
    assert has_element?(view, "#message-form #composer-error.composer-eyebrow")
    assert has_element?(view, ~s(#chat_message[aria-describedby="composer-error"]))

    # The send action stays an icon-only control carrying its accessible name.
    assert has_element?(view, ~s(#message-form #send-message[aria-label="Send"]))
  end

  test "sending a message resets the composer so the draft cannot stick", %{conn: conn} do
    conn = log_in_github_user(conn, "composer-clear-browser")
    {:ok, view, _html} = live(conn, ~p"/chat")

    view
    |> form("#message-form", chat: %{message: "The draft must not remain after send."})
    |> render_submit()

    assert view |> element("#chat_message") |> render() =~
             ~r/<textarea[^>]*id="chat_message"[^>]*>\s*<\/textarea>/

    assert eventually(fn ->
             html = render(view)

             html =~ "You said: The draft must not remain after send." and
               not (html =~ ~s(id="cancel-turn"))
           end)
  end

  test "the sidebar carries the shared destinations for an account that has written",
       %{conn: conn} do
    conn = log_in_chatting_user(conn, "computers-nav-browser")
    {:ok, view, _html} = live(conn, ~p"/chat")

    # Computers, Memory and Leaderboard are destinations for everyone, so they
    # sit in the application sidebar rather than appearing only on chat.
    assert has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/computers"]))
    assert has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/memory"]))
    # Leaderboard is a secondary destination, so it sits in the footer with the
    # docs and the component library rather than in the working nav.
    assert has_element?(view, ~s(#sidebar .sidebar-footer a[href="/leaderboard"]))
  end

  test "chat contributes its rows to the one application sidebar", %{conn: conn} do
    conn = log_in_github_user(conn, "sidebar-shell-browser")
    {:ok, view, _html} = live(conn, ~p"/chat")

    # Chat used to render a second, complete application shell inside the
    # first: its own brand, rail and account footer, nested in the padded main
    # of a layout that already had all three. It now contributes rows to the
    # sidebar the layout owns, so there is exactly one of each.
    assert has_element?(view, "#sidebar")
    assert view |> render() |> String.split("<aside") |> length() == 2
    refute has_element?(view, "#sidebar-scrim")
    refute has_element?(view, "#mobile-menu")
    refute has_element?(view, "#sidebar-toggle")

    # Every destination chat used to carry in its own rail is still reachable,
    # with an accessible name on each stretched hit target.
    # Export is the conversation's action, so it is in the conversation's
    # header menu rather than a permanent sidebar row.
    refute has_element?(view, "#sidebar #export-atif")

    assert has_element?(
             view,
             "#chat-actions-menu a#export-atif[href='/data/export/atif'][download]"
           )

    assert has_element?(view, "#sidebar #sidebar-sections")

    # Identity is the command bar's, once, rather than a second account
    # control in a second footer.
    assert has_element?(view, "#account-bar-trigger")
    refute has_element?(view, "#sidebar #account-menu-trigger")
  end

  test "the admin row renders only for an operator", %{conn: conn} do
    conn = log_in_github_user(conn, "admin-chip-hidden-browser")
    {:ok, _view, html} = live(conn, ~p"/chat")
    refute html =~ ~s(id="open-admin")

    conn = log_in_admin_user(recycle(conn), "admin-chip-visible-browser")
    {:ok, view, _html} = live(conn, ~p"/chat")
    # Admin is one row in the sidebar footer for an operator on every page,
    # rather than a row that exists only on chat.
    assert has_element?(view, ~s(#sidebar .sidebar-footer #open-admin[href="/admin"]))
  end

  test "the reset control renders only where it is enabled", %{conn: conn} do
    original = Application.get_env(:openagents, :conversation_reset_enabled, false)
    on_exit(fn -> Application.put_env(:openagents, :conversation_reset_enabled, original) end)

    Application.put_env(:openagents, :conversation_reset_enabled, true)
    conn = log_in_github_user(conn, "reset-visible-browser")
    {:ok, _view, html} = live(conn, ~p"/chat")
    assert html =~ ~s(id="reset-conversation")

    Application.put_env(:openagents, :conversation_reset_enabled, false)
    conn = log_in_github_user(recycle(conn), "reset-hidden-browser")
    {:ok, _view, html} = live(conn, ~p"/chat")
    refute html =~ ~s(id="reset-conversation")
  end

  test "plain message text is flush with its tags so pre-wrap renders nothing extra" do
    # Ported from Sarah: the file this reads was `lib/sarah_web/live/chat_live.ex`
    # there. Only the path changed with the re-namespacing — the assertion below
    # is unchanged and still guards the same markup.
    template = File.read!("lib/openagents_web/live/chat_live.ex")

    # `.message-content` is `white-space: pre-wrap`, which is what preserves the
    # line breaks a person actually typed. Any newline or indentation the
    # formatter puts around the interpolation becomes content and renders as a
    # blank line, so the interpolation stays flush and `phx-no-format` keeps it
    # that way. Assistant prose goes through Markdown and is not affected.
    assert template =~ ~r/phx-no-format\s*\n\s*>\{@message\.content\}<\/p>/
  end

  test "presents one continuing conversation after authentication", %{conn: conn} do
    user = github_user("live-browser")
    conn = log_in_github_user(conn, "live-browser")
    assert {:ok, view, html} = live(conn, ~p"/chat")

    assert html =~ "OpenAgents"
    assert html =~ "Message Sarah"
    assert html =~ "Hello. I&#39;m Sarah—an OpenAgent. What are we working on?"
    assert html =~ ~s(href="/favicon.ico")
    assert html =~ ~s(href="/favicon-32x32.png")
    assert html =~ ~s(href="/favicon-16x16.png")
    assert html =~ ~s(href="/apple-touch-icon.png")
    refute html =~ "favicon.svg"
    refute html =~ "Settings"
    refute html =~ ~s(id="voice-controller")
    assert html =~ "@#{user.github_login}"

    assert has_element?(
             view,
             "#account-bar-trigger[popovertarget='account-bar-menu'] img[src='#{user.github_avatar_url}']"
           )

    assert has_element?(view, "#account-bar-menu[popover=auto][role=menu]")

    assert has_element?(
             view,
             "#account-bar-menu form[action='/logout'] button[role=menuitem]"
           )

    refute html =~ "CONNECTED / THIS BROWSER"
  end

  test "recording off makes no claim that calls are recorded", %{conn: conn} do
    previous_voice = Application.fetch_env!(:openagents, :voice)
    previous_recording = Application.fetch_env!(:openagents, :voice_recording)
    Application.put_env(:openagents, :voice, enabled_voice())

    Application.put_env(
      :openagents,
      :voice_recording,
      Keyword.put(previous_recording, :enabled, false)
    )

    on_exit(fn ->
      Application.put_env(:openagents, :voice, previous_voice)
      Application.put_env(:openagents, :voice_recording, previous_recording)
    end)

    conn = log_in_github_user(conn, "voice-recording-off-user")
    assert {:ok, view, html} = live(conn, ~p"/chat")

    assert html =~ ~s(id="voice-controller")
    refute has_element?(view, "#voice-recording-disclosure")
    assert html =~ ~s(data-recording-enabled="false")
  end

  test "a connected LiveView refuses events after the account is banned", %{conn: conn} do
    user = github_user("live-ban-user")
    conn = log_in_github_user(conn, "live-ban-user")
    assert {:ok, view, _html} = live(conn, ~p"/chat")
    assert {:ok, _banned} = OpenAgents.Accounts.ban_user(user, "manual_abuse_review")

    view |> form("#message-form", chat: %{message: "still here?"}) |> render_submit()
    assert_redirect(view, ~p"/")
  end

  test "voice controls project fenced server state and typing closes a runtime-less session honestly",
       %{conn: conn} do
    previous_voice = Application.fetch_env!(:openagents, :voice)
    Application.put_env(:openagents, :voice, enabled_voice())
    on_exit(fn -> Application.put_env(:openagents, :voice, previous_voice) end)

    token = "voice-live-browser-credential-000000000000000000"
    user = github_user(token)
    conn = log_in_github_user(conn, token)
    assert {:ok, view, html} = live(conn, ~p"/chat")

    assert html =~ ~s(id="voice-controller")
    assert html =~ ~s(phx-hook="VoiceController")
    assert html =~ ~s(data-server-status="idle")
    assert html =~ ~s(id="voice-start")
    assert html =~ ~s(id="voice-mute")
    assert html =~ ~s(id="voice-interrupt")
    assert html =~ ~s(id="voice-end")
    assert html =~ ~s(role="status")
    assert has_element?(view, "#message-form #voice-start[aria-label='Start voice']")
    assert has_element?(view, "#voice-status.visually-hidden")
    refute has_element?(view, "#voice-start", "START VOICE")
    refute has_element?(view, ".voice-state-line")
    # The status line states lifecycle and microphone state; retention is stated
    # once, by the disclosure, and never contradicted here.
    refute html =~ "AUDIO NOT STORED"
    refute html =~ "OPENAI_API_KEY"
    refute html =~ "rtc_"

    conversation = Conversations.get_conversation_for_user(user)
    {:ok, session} = Voice.admit_session(conversation, Voice.Config.current!())

    assert {:ok, listening, _event, :created} =
             Voice.record_provider_event(session, session.generation, %Voice.ProviderEvent{
               kind: :sideband_connected,
               provider_event_id: nil,
               payload: %{}
             })

    assert eventually(fn ->
             rendered = render(view)

             rendered =~ ~s(data-server-status="listening") and
               rendered =~ ~s(data-server-generation="1")
           end)

    view
    |> form("#message-form", chat: %{message: "Continue this in typed chat."})
    |> render_submit()

    assert eventually(fn ->
             rendered = render(view)

             rendered =~ "You said: Continue this in typed chat." and
               rendered =~ ~s(data-server-status="ended")
           end)

    ended = Voice.get_session!(listening.id)
    assert ended.status == "ended"
    assert ended.termination_reason == "voice_runtime_missing"
  end

  test "typing during a live voice call keeps the call open and hands voice the message", %{
    conn: conn
  } do
    previous_voice = Application.fetch_env!(:openagents, :voice)
    Application.put_env(:openagents, :voice, enabled_voice())
    Application.put_env(:openagents, :voice_call_test_observer, self())
    Application.put_env(:openagents, :voice_sideband_test_observer, self())

    on_exit(fn ->
      Application.put_env(:openagents, :voice, previous_voice)
      Application.delete_env(:openagents, :voice_call_test_observer)
      Application.delete_env(:openagents, :voice_sideband_test_observer)
    end)

    token = "voice-typed-inject-credential-00000000000000000"
    user = github_user(token)
    conn = log_in_github_user(conn, token)
    assert {:ok, view, _html} = live(conn, ~p"/chat")

    conversation = Conversations.get_conversation_for_user(user)

    assert {:ok, session, _admission} =
             OpenAgents.VoiceSessions.connect(
               conversation,
               "v=0\r\no=typed-live-offer",
               String.duplicate("a", 64),
               Voice.Config.current!()
             )

    assert_receive {:sideband_started, _sideband, _sideband_session}

    assert eventually(fn ->
             render(view) =~ ~s(data-server-status="listening")
           end)

    typed = "Read https://github.com/OpenAgentsInc/openagents.com while we talk."

    view
    |> form("#message-form", chat: %{message: typed})
    |> render_submit()

    assert_receive {:sideband_event_sent, %{"type" => "conversation.item.create", "item" => item}}

    assert item["role"] == "user"
    assert [%{"type" => "input_text", "text" => ^typed}] = item["content"]

    assert eventually(fn ->
             rendered = render(view)

             rendered =~ "Read https://github.com/OpenAgentsInc/openagents.com" and
               rendered =~ ~s(data-server-status="listening")
           end)

    # No text turn opened: voice still owns the response chronology.
    refute render(view) =~ "You said: Read"

    stored = Voice.get_session!(session.id)
    assert stored.status == "listening"
    assert {:ok, _ended} = OpenAgents.VoiceSessions.end_session(stored)
  end

  test "live voice transcript deltas render immediately and yield to the durable message", %{
    conn: conn
  } do
    user = github_user("live-voice-delta-browser")
    conn = log_in_github_user(conn, "live-voice-delta-browser")
    assert {:ok, view, _html} = live(conn, ~p"/chat")
    conversation = Conversations.get_conversation_for_user(user)

    send(view.pid, {
      :voice_live_transcript,
      %{
        voice_session_id: Ecto.UUID.generate(),
        conversation_id: conversation.id,
        item_id: "item-live-1",
        role: "assistant",
        content: "The first"
      }
    })

    assert render(view) =~ "The first"

    send(view.pid, {
      :voice_live_transcript,
      %{
        voice_session_id: Ecto.UUID.generate(),
        conversation_id: conversation.id,
        item_id: "item-live-1",
        role: "assistant",
        content: "The first words."
      }
    })

    html = render(view)
    assert html =~ "The first words."
    assert has_element?(view, "#messages-voice-live-item-live-1")

    durable = %Message{
      id: Ecto.UUID.generate(),
      conversation_id: conversation.id,
      role: "assistant",
      content: "The first words. All of them.",
      status: "complete",
      modality: "voice",
      provider_item_id: "item-live-1",
      transcript_kind: "provider_output_transcript"
    }

    send(view.pid, {:message_updated, durable})

    html = render(view)
    assert html =~ "The first words. All of them."
    refute has_element?(view, "#messages-voice-live-item-live-1")
  end

  test "reload preserves one canonical greeting without fake recognition", %{conn: conn} do
    key = "reload-browser-credential-0000000000000000"
    user = github_user(key)
    conn = log_in_github_user(conn, key)

    assert {:ok, first_view, first_html} = live(conn, ~p"/chat")
    GenServer.stop(first_view.pid)
    assert {:ok, _second_view, second_html} = live(conn, ~p"/chat")

    assert first_html =~ "Hello. I&#39;m Sarah—an OpenAgent. What are we working on?"
    assert second_html =~ "Hello. I&#39;m Sarah—an OpenAgent. What are we working on?"
    refute second_html =~ "Welcome back"

    conversation = Conversations.get_conversation_for_user(user)

    greeting_count =
      OpenAgents.Repo.aggregate(
        from(m in Message,
          where:
            m.conversation_id == ^conversation.id and m.role == "assistant" and
              m.content == "Hello. I'm Sarah—an OpenAgent. What are we working on?"
        ),
        :count
      )

    assert greeting_count == 1
  end

  test "turn execution receives the installed Sarah persona and default role", %{conn: conn} do
    conn = log_in_github_user(conn, "persona-browser")
    assert {:ok, view, _html} = live(conn, ~p"/chat")

    view
    |> form("#message-form", chat: %{message: "[inspect-persona]"})
    |> render_submit()

    assert eventually(fn ->
             html = render(view)
             html =~ "Sarah persona and role received." and not (html =~ ~s(id="cancel-turn"))
           end)
  end

  test "sends, streams, and durably stores a complete turn", %{conn: conn} do
    user = github_user("durable-turn-user")
    conn = log_in_github_user(conn, "durable-turn-user")
    assert {:ok, view, _html} = live(conn, ~p"/chat")
    conversation = Conversations.get_conversation_for_user(user)

    view
    |> form("#message-form", chat: %{message: "Help me reason about this."})
    |> render_submit()

    assert eventually(fn ->
             html = render(view)

             # The composer is usable again: the send control is a glyph now, so
             # this asserts the control's state rather than a visible word.
             html =~ "You said: Help me reason about this." and
               html =~ ~s(id="send-message") and
               not (html =~ ~s(id="send-message" disabled)) and
               not (html =~ ~s(id="cancel-turn"))
           end)

    # Asymmetry carries the roles (DESIGN.md, Message row): the person's
    # message is the tinted bubble, Sarah's stays bare prose with no bubble
    # and no avatar column.
    assert has_element?(view, ".message-row--user .message-content.message-bubble")
    refute has_element?(view, ".message-row--assistant .message-bubble")
    refute has_element?(view, ".message-row .avatar")

    persisted =
      OpenAgents.Repo.all(
        from(m in Message,
          where: m.conversation_id == ^conversation.id,
          order_by: [asc: m.inserted_at, asc: m.id]
        )
      )

    assert Enum.any?(
             persisted,
             &(&1.role == "user" and &1.content == "Help me reason about this.")
           )

    assert Enum.any?(persisted, fn message ->
             message.role == "assistant" and
               message.status == "complete" and
               message.content =~ "You said: Help me reason about this."
           end)
  end

  test "each message carries a labeled hover toolbar and an accessible timestamp", %{conn: conn} do
    conn = log_in_github_user(conn, "toolbar-browser-credential-000000000000000000000")
    assert {:ok, view, html} = live(conn, ~p"/chat")

    view
    |> form("#message-form", chat: %{message: "Toolbar please."})
    |> render_submit()

    assert eventually(fn ->
             html = render(view)
             html =~ "You said: Toolbar please." and not (html =~ ~s(id="cancel-turn"))
           end)

    # Copy actions are icon-only, so the accessible name lives on the control.
    assert has_element?(
             view,
             ~s(.message-row--user .message-toolbar button[data-copy-kind="message"][aria-label="Copy message"])
           )

    assert has_element?(
             view,
             ~s(.message-row--user .message-toolbar button[data-copy-kind="link"][aria-label="Copy message link"])
           )

    assert has_element?(
             view,
             ~s(.message-row--assistant .message-toolbar button[data-copy-kind="message"])
           )

    # The timestamp is hover-revealed visually but always in the tree.
    assert has_element?(view, ".message-row--user .message-toolbar time[datetime]")

    # The code-copy pill ships from the template with its vendored glyph and
    # accessible name; the transcript hook clones it into rendered wells.
    assert html =~ ~s(id="code-copy-template")
    assert html =~ ~s(aria-label="Copy code")
  end

  test "reload reconstructs bounded tool activity without provider identifiers", %{conn: conn} do
    token = "tool-reload-browser-credential-0000000000000000"
    %{turn: turn, step: step} = begin_tool_turn(token, "durable-query-marker")
    assert {:ok, _running_step, :started} = Conversations.start_tool_step(step)

    conn = log_in_github_user(conn, token)
    assert {:ok, view, html} = live(conn, ~p"/chat")

    # The event header renders the durable scrubbed values: the subject
    # sentence plus the bounded argument excerpt, per issue #79.
    assert html =~ ~s(id="tool-activity-step-#{step.id}")
    assert html =~ "Working on a look back through this conversation"
    assert html =~ "query=durable-query-marker"
    assert html =~ ~s(role="status")
    assert html =~ ~s(aria-live="polite")
    refute html =~ step.provider_call_id
    refute html =~ step.provider_item_id
    refute html =~ step.provider_response_id

    # The disclosure anatomy: an aria-expanded chevron button controlling a
    # details region that carries the bounded arguments.
    assert has_element?(
             view,
             ~s(#tool-activity-step-#{step.id} button[aria-expanded="false"][aria-controls="tool-activity-step-#{step.id}-details"])
           )

    assert has_element?(view, "#tool-activity-step-#{step.id}-details")
    assert html =~ "ARGUMENTS"

    step_id = step.id
    assigns = :sys.get_state(view.pid).socket.assigns
    assert [%{id: ^step_id, status: "running"} = activity] = assigns.tool_activity
    refute Map.has_key?(activity, :provider_call_id)
    refute Map.has_key?(activity, :provider_item_id)
    refute Map.has_key?(activity, :provider_response_id)

    assert {:ok, _cancelled_turn} = Conversations.cancel_turn(turn)
  end

  test "activity shows actual terminal status and executor then clears with the turn", %{
    conn: conn
  } do
    token = "tool-terminal-browser-credential-00000000000000"
    %{turn: turn, receipt: receipt, step: step} = begin_tool_turn(token, "bounded-query")

    conn = log_in_github_user(conn, token)
    assert {:ok, view, _html} = live(conn, ~p"/chat")
    assert render(view) =~ "Getting ready for a look back through this conversation"

    assert {:ok, _running_step, :started} = Conversations.start_tool_step(step)

    assert eventually(fn ->
             render(view) =~ "Working on a look back through this conversation"
           end)

    assert {:ok, _completed_step} =
             Conversations.complete_tool_step(
               step,
               tool_outcome(step, "refused", "policy_refused")
             )

    assert eventually(fn ->
             html = render(view)

             html =~ "A look back through this conversation wasn&#39;t permitted" and
               html =~ "EXECUTOR / Sarah policy worker"
           end)

    # The executor disclosure's home is the expansion, not the collapsed row
    # (issue #79): it renders verbatim inside the step's details region.
    assert has_element?(
             view,
             "#tool-activity-step-#{step.id}-details",
             "EXECUTOR / Sarah policy worker"
           )

    assert {:ok, succeeded_step, :created} =
             request_tool_step(turn, receipt, "succeeded-query")

    assert {:ok, _succeeded_step} =
             Conversations.complete_tool_step(succeeded_step, succeeded_outcome(succeeded_step))

    assert {:ok, timed_out_step, :created} =
             request_tool_step(turn, receipt, "timed-out-query")

    assert {:ok, _timed_out_step} =
             Conversations.complete_tool_step(
               timed_out_step,
               tool_outcome(timed_out_step, "failed", "timeout")
             )

    assert eventually(fn ->
             html = render(view)

             # The composer no longer blocks during a turn — Stop signals the
             # active turn; the input stays usable for queuing.
             html =~ "Finished a look back through this conversation" and
               html =~ "Couldn&#39;t finish a look back through this conversation" and
               has_element?(view, "#cancel-turn") and
               has_element?(view, "#chat_message:not([disabled])")
           end)

    assert {:ok, _failed_turn} = Conversations.fail_turn(turn, :test_terminal)

    assert eventually(fn ->
             html = render(view)

             # Activity is part of the transcript now, so it outlives the turn
             # that produced it instead of vanishing with the composer band.
             html =~ ~s(id="tool-activity-step-) and
               not (html =~ ~s(id="cancel-turn")) and
               has_element?(view, "#chat_message:not([disabled])")
           end)
  end

  test "cancel remains usable during slow tool execution and keeps activity", %{conn: conn} do
    Application.put_env(:openagents, :test_tool_observer, self())
    on_exit(fn -> Application.delete_env(:openagents, :test_tool_observer) end)

    conn = log_in_github_user(conn, "tool-cancel-live-browser-credential-000000000000")

    assert {:ok, view, _html} = live(conn, ~p"/chat")

    view
    |> form("#message-form", chat: %{message: "[cancel-tool-loop]"})
    |> render_submit()

    assert_receive {:test_tool_executed, _tool_pid, "block", _scope_ref}, 1_000

    assert eventually(fn ->
             render(view) =~ "Working on a look back through this conversation"
           end)

    assert has_element?(view, "#cancel-turn")

    view |> element("#cancel-turn") |> render_click()

    assert eventually(fn ->
             html = render(view)

             # Activity is part of the transcript now, so it outlives the turn
             # that produced it instead of vanishing with the composer band.
             html =~ ~s(id="tool-activity-step-) and
               not (html =~ ~s(id="cancel-turn")) and
               has_element?(view, "#chat_message:not([disabled])")
           end)
  end

  test "the composer never blocks: a message sent during a turn queues and runs next", %{
    conn: conn
  } do
    Application.put_env(:openagents, :test_tool_observer, self())
    on_exit(fn -> Application.delete_env(:openagents, :test_tool_observer) end)

    conn = log_in_github_user(conn, "queue-live-browser-credential-00000000000000")
    assert {:ok, view, _html} = live(conn, ~p"/chat")

    # Start a turn that stays active (its tool blocks).
    view |> form("#message-form", chat: %{message: "[cancel-tool-loop]"}) |> render_submit()
    assert_receive {:test_tool_executed, _tool_pid, "block", _scope_ref}, 1_000

    # The composer is NOT disabled during the turn (the fix) and Stop is present.
    assert has_element?(view, "#chat_message:not([disabled])")
    assert has_element?(view, "#cancel-turn")

    # Sending another message queues it rather than erroring with turn-in-progress.
    view
    |> form("#message-form", chat: %{message: "Help me reason about this."})
    |> render_submit()

    assert has_element?(view, "#message-queue", "Help me reason about this.")
    refute render(view) =~ "still responding"

    # Cancelling the running turn starts the queued message, which runs to
    # completion and drains the queue.
    view |> element("#cancel-turn") |> render_click()

    assert eventually(fn ->
             render(view) =~ "You said: Help me reason about this."
           end)

    refute has_element?(view, "#message-queue")
  end

  test "a second browser cannot render or read the first browser's adversarial source ID", %{
    conn: conn
  } do
    foreign_token = "live-foreign-source-browser-credential-0000000000"
    local_token = "live-local-source-browser-credential-000000000000"
    assert {:ok, foreign} = Conversations.ensure_conversation(github_user(foreign_token))

    source =
      OpenAgents.Repo.insert!(%Message{
        conversation_id: foreign.id,
        role: "user",
        content: "private-live-boundary-marker-73",
        status: "complete"
      })

    Application.put_env(:openagents, :test_foreign_source_ref, "message:#{source.id}")
    on_exit(fn -> Application.delete_env(:openagents, :test_foreign_source_ref) end)

    local_user = github_user(local_token)
    local_conn = log_in_github_user(conn, local_token)
    assert {:ok, local_view, local_html} = live(local_conn, ~p"/chat")
    refute local_html =~ "private-live-boundary-marker-73"

    local_view
    |> form("#message-form", chat: %{message: "[foreign-source-read]"})
    |> render_submit()

    assert eventually(fn ->
             html = render(local_view)

             html =~ "Recall source outcome: failed." and
               not (html =~ "private-live-boundary-marker-73")
           end)

    # The attempted source ref is this account's own durable argument truth and
    # may render inside the step's activity details (issue #79). The foreign
    # content — and the foreign ID as message content — must never render.
    contents =
      render(local_view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.filter(".message-content")
      |> LazyHTML.text()

    refute contents =~ source.id
    refute contents =~ "private-live-boundary-marker-73"

    local = Conversations.get_conversation_for_user(local_user)

    [turn] =
      OpenAgents.Repo.all(
        from(turn in OpenAgents.Conversations.Turn, where: turn.conversation_id == ^local.id)
      )

    [step] =
      OpenAgents.Repo.all(
        from(step in OpenAgents.Conversations.ToolStep, where: step.turn_id == ^turn.id)
      )

    assert step.status == "failed"
    assert step.error["code"] == "not_found"
    assert step.target_receipt_refs == []
  end

  test "a rejected memory secret reaches no LiveView assign, provider input, or turn receipt", %{
    conn: conn
  } do
    token = "profile-policy-live-browser-credential-000000000000"
    secret = "sk-" <> "proj-LIVEPRIVATEVALUE12345678901234567890"
    assert {:ok, conversation} = Conversations.ensure_conversation(github_user(token))
    owner = OpenAgents.Repo.get!(Visitor, conversation.visitor_id)

    assert {:error, {:memory_policy_rejected, "api_token"}} =
             ProfileMemory.create_candidate(owner, %{
               category: "preference",
               claim: secret,
               creator: "user_explicit",
               provenance: %{"intent" => "remember"},
               owner_asserted: true,
               sources: []
             })

    Application.put_env(:openagents, :test_provider_observer, self())
    on_exit(fn -> Application.delete_env(:openagents, :test_provider_observer) end)

    conn = log_in_github_user(conn, token)
    assert {:ok, view, html} = live(conn, ~p"/chat")
    refute html =~ secret
    refute inspect(:sys.get_state(view.pid).socket.assigns) =~ secret

    view
    |> form("#message-form", chat: %{message: "[observe-request]"})
    |> render_submit()

    assert_receive {:provider_request, provider_pid, request}, 1_000
    refute inspect(request) =~ secret
    send(provider_pid, :continue_provider)

    assert eventually(fn -> render(view) =~ "Observed model" end)
    refute render(view) =~ secret
    refute inspect(:sys.get_state(view.pid).socket.assigns) =~ secret

    turn =
      OpenAgents.Repo.one!(
        from(turn in OpenAgents.Conversations.Turn,
          where: turn.conversation_id == ^conversation.id,
          order_by: [desc: turn.inserted_at],
          limit: 1
        )
      )

    assert {:ok, receipt} = Conversations.get_turn_receipt(turn)
    refute inspect(receipt) =~ secret
  end

  test "bounded export uses safe account-scoped public projections", %{conn: conn} do
    token = "memory-export-browser-credential-000000000000000"
    %{record: record} = create_profile_memory(token, "My project is One", "project")
    conn = log_in_github_user(conn, token)
    response = get(conn, ~p"/memory/export")

    assert response.status == 200
    assert get_resp_header(response, "content-type") |> List.first() =~ "application/json"

    assert get_resp_header(response, "content-disposition") == [
             ~s(attachment; filename="sarah-memory-account.json")
           ]

    export = Jason.decode!(response.resp_body)
    assert export["schema"] == "sarah.profile_memory_account_export.v1"
    assert export["scope"] == "authenticated_github_user"

    assert [%{"id" => id, "claim" => "My project is One", "projection" => "admitted"}] =
             export["records"]

    assert id == record.id
    refute response.resp_body =~ "tool_outputs"
    refute response.resp_body =~ "instructions"
    refute response.resp_body =~ "INTERNAL_TEST_PAYLOAD"
  end

  defp begin_tool_turn(token, query) do
    assert {:ok, conversation} = Conversations.ensure_conversation(github_user(token))
    assert {:ok, records} = Conversations.create_turn(conversation, "Recall something.")
    context = Composer.compose!()

    request = %Request{
      model_id: "tool-ui-model",
      instructions: context.instructions,
      input: Conversations.provider_messages(conversation.id)
    }

    assert {:ok, inference} =
             Conversations.begin_inference(records.turn, context, request, "test.provider",
               tool_catalog_digest: OpenAgents.Tools.Registry.current!().digest
             )

    assert {:ok, step, :created} = request_tool_step(inference.turn, inference.receipt, query)

    %{turn: inference.turn, receipt: inference.receipt, step: step}
  end

  defp create_profile_memory(token, claim, category) do
    assert {:ok, conversation} = Conversations.ensure_conversation(github_user(token))
    owner = Conversations.get_conversation_owner!(conversation)

    source =
      OpenAgents.Repo.insert!(%Message{
        conversation_id: conversation.id,
        role: "user",
        content: "Remember that #{claim}",
        status: "complete"
      })

    assert {:ok, %{record: record}} =
             ProfileMemory.remember_explicit(owner, %{
               category: category,
               claim: claim,
               creator: "user_explicit",
               provenance: %{
                 "operation" => "test_explicit_memory",
                 "tool_payload" => "INTERNAL_TEST_PAYLOAD"
               },
               sources: [%{source_ref: "message:#{source.id}", kind: "owner_statement"}]
             })

    %{record: record, source: source, owner: owner}
  end

  defp request_tool_step(turn, receipt, query) do
    artifact =
      Map.fetch!(OpenAgents.Tools.Registry.current!().modules, {"sarah.tool.recall_messages", 1})

    routing_receipt = routing_receipt!(receipt, "call-ui-#{query}", artifact)
    policy = artifact.attribution_policy

    Conversations.request_tool_step(turn, receipt, %{
      provider_call_id: "call-ui-#{query}",
      provider_item_id: "item-ui-#{query}",
      provider_response_id: "response-ui-#{query}",
      tool_name: "recall_messages",
      tool_version: 1,
      module_id: "sarah.tool.recall_messages",
      module_artifact_digest: artifact.artifact_digest,
      executor_implementation_digest: artifact.implementation_digest,
      routing_receipt_id: routing_receipt.id,
      side_effect_class: artifact.side_effect_class,
      attribution_policy_id: policy["id"],
      attribution_policy_version: policy["version"],
      attribution_policy_digest: policy["digest"],
      cost_units: artifact.facets["cost_units"],
      raw_arguments: Jason.encode!(%{"query" => query})
    })
  end

  defp routing_receipt!(receipt, call_id, artifact) do
    snapshot = OpenAgents.Tools.Registry.current!()
    policy = OpenAgents.Modules.RoutingPolicy.default()

    proposal = %{
      "module_id" => artifact.module_id,
      "version" => artifact.version,
      "artifact_digest" => artifact.artifact_digest,
      "registry_digest" => snapshot.digest
    }

    assert {:ok, decision} =
             OpenAgents.Modules.Router.route(snapshot, policy, %{
               intent_digest: receipt.input_digest,
               required_capability: "conversation.read",
               required_side_effect: "read_only",
               surface: "text",
               data_scope: "browser_conversation",
               authorities: MapSet.new(["conversation.read"]),
               proposal: proposal,
               exact_proposal: true
             })

    assert {:ok, route} =
             OpenAgents.Modules.RoutingReceipts.persist(receipt.id, call_id, decision)

    route
  end

  defp succeeded_outcome(step) do
    tool_outcome(step, "succeeded", nil)
    |> Map.put("result", %{"matches" => []})
    |> Map.put("error", nil)
  end

  defp tool_outcome(step, status, code) do
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
        "id" => "sarah.policy.worker",
        "disclosure" => "Sarah policy worker",
        "implementation_digest" => step.executor_implementation_digest
      },
      "status" => status,
      "result" => nil,
      "error" => %{"code" => code, "message" => "The capability did not complete."},
      "target_receipt_refs" => [],
      "attribution_refs" => [],
      "started_at" => now,
      "completed_at" => now
    }
  end

  defp eventually(assertion, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(assertion, deadline)
  end

  defp enabled_voice do
    [
      enabled: true,
      architecture: :openai_realtime,
      provider: "openai",
      model: "gpt-realtime-2.1",
      voice: "marin",
      reasoning_effort: "low",
      maximum_session_seconds: 3_000
    ]
  end

  defp do_eventually(assertion, deadline) do
    if assertion.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        receive do
          _message -> :ok
        after
          10 -> :ok
        end

        do_eventually(assertion, deadline)
      end
    end
  end
end
