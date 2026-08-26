defmodule OpenAgentsWeb.ChatConsoleLive do
  @moduledoc """
  The GLM 5.3 Flash console, reachable at `/chat` by operators only.

  The console drives one GLM 5.3 Flash conversation per operator account. It
  sends every request to OpenRouter from the server, so the provider credential
  never reaches the browser, and it prefers the Responses API, using chat
  completions only when a provider cannot serve Responses.

  It shares the AI Elements components with Sarah's transcript at `/sarah` and
  shares none of her state: no persona, no voice, no work queue, and no
  conversation of hers. The model is fixed, so there is no model picker, and
  reasoning, tool calls, usage, and provider lane appear only when the provider
  reports them.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Box.Fleet
  alias OpenAgents.Chat.{AccountTurns, OpenRouter, TokenUsage}
  alias OpenAgents.Conversations
  alias OpenAgents.Delegations
  alias OpenAgentsWeb.LiveRefresh

  @suggestions [
    "Summarize what the stress fleet measures today.",
    "Draft a checklist for a cloud-computer stress run.",
    "Explain the difference between a push and a deploy here.",
    "Write a short status update for the current fleet work."
  ]

  @fleet_fast_refresh_interval_ms 1_000
  @fleet_settled_refresh_interval_ms 5_000
  @fleet_idle_refresh_interval_ms 10_000

  @reasoning_options [
    {"Reasoning off", "none"},
    {"Minimal reasoning", "minimal"},
    {"Low reasoning", "low"},
    {"Medium reasoning", "medium"},
    {"High reasoning", "high"},
    {"Maximum reasoning", "max"}
  ]

  import OpenAgentsWeb.AI.PromptInput,
    only: [
      prompt_input: 1,
      prompt_input_textarea: 1,
      prompt_input_toolbar: 1,
      prompt_input_tools: 1,
      prompt_input_submit: 1
    ]

  import OpenAgentsWeb.AI.Conversation,
    only: [
      conversation: 1,
      conversation_content: 1,
      conversation_empty_state: 1,
      message: 1,
      message_content: 1,
      message_actions: 1,
      message_action: 1,
      suggestions: 1,
      suggestion: 1
    ]

  import OpenAgentsWeb.AI.Evidence, only: [context: 1]

  import OpenAgentsWeb.AI.Reasoning,
    only: [
      reasoning: 1,
      reasoning_trigger: 1,
      reasoning_content: 1,
      tool: 1,
      tool_header: 1,
      tool_content: 1,
      tool_input: 1,
      tool_output: 1
    ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, conversation} = Conversations.ensure_conversation(socket.assigns.current_user)
    messages = AccountTurns.list_messages(socket.assigns.current_user)

    socket =
      socket
      |> LiveRefresh.init()
      |> assign(:page_title, "Chat")
      |> assign(:conversation, conversation)
      |> assign(:fleet, Delegations.projection(socket.assigns.current_user, conversation.id))
      |> assign(:form, composer_form())
      |> assign(:reasoning_options, @reasoning_options)
      |> assign(:model_label, OpenRouter.model_label())
      |> assign(:suggestions, @suggestions)
      |> assign_messages(messages)
      |> assign(:assistant_response, nil)
      |> assign(:assistant_reasoning, nil)
      |> assign(:assistant_tool_calls, [])
      |> assign(:assistant_blocks, [])
      |> assign(:reasoning_started_at, nil)
      |> assign(:streaming?, false)
      |> assign(:last_prompt, "")
      |> assign(:stream_id, nil)

    # The transcript is a projection of `account_chat_runs`, which the API and
    # another browser session both write. `Conversations.subscribe/1` is the
    # wrong topic for it -- those writes never create a `Conversations.Message`
    # -- so the console listens on the turn topic the runs themselves announce
    # on, and re-reads through `list_messages/1`, which resolves this account's
    # own conversation.
    if connected?(socket) do
      AccountTurns.subscribe_turns(conversation.id)
      schedule_fleet_refresh(socket)
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("submit_message", %{"chat" => chat_params}, socket) do
    message = Map.get(chat_params, "message", "")
    reasoning = OpenRouter.reasoning_effort(Map.get(chat_params, "reasoning"))
    message = String.trim(message)

    if message == "" or socket.assigns.streaming? do
      {:noreply, socket}
    else
      submit_message(socket, message, reasoning)
    end
  end

  def handle_event("stop_response", _params, socket) do
    case AccountTurns.cancel(socket.assigns.current_user) do
      {:ok, _run} -> {:noreply, reset_stream(socket)}
      {:error, :no_active_turn} -> {:noreply, reset_stream(socket)}
    end
  end

  def handle_event("stop_box", %{"box-id" => box_id}, socket) do
    case Fleet.stop(socket.assigns.current_user, box_id) do
      {:ok, _projection} ->
        {:noreply, refresh_fleet(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_fleet()
         |> put_flash(:error, stop_box_error_message(reason))}
    end
  end

  def handle_event("cancel_box_run", %{"box-id" => box_id, "run-id" => run_id}, socket) do
    case Fleet.cancel_run(socket.assigns.current_user, box_id, run_id) do
      {:ok, _run} ->
        {:noreply, refresh_fleet(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_fleet()
         |> put_flash(:error, cancel_box_run_error_message(reason))}
    end
  end

  def handle_event("retry_message", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)
    reasoning = current_reasoning(socket)

    if prompt == "" or socket.assigns.streaming? do
      {:noreply, socket}
    else
      submit_message(socket, prompt, reasoning)
    end
  end

  def handle_event("use_suggestion", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, :form, composer_form(current_reasoning(socket), prompt))}
  end

  @impl true
  def handle_info({:openrouter_stream_event, stream_id, {:text_delta, delta}}, socket) do
    case socket.assigns do
      %{stream_id: ^stream_id, streaming?: true} ->
        {:noreply,
         socket
         |> update(:assistant_response, &(&1 <> delta))
         |> append_streaming_delta(:content, delta)}

      _stale_stream ->
        {:noreply, socket}
    end
  end

  def handle_info({:openrouter_stream_event, stream_id, {:reasoning_delta, delta}}, socket) do
    case socket.assigns do
      %{stream_id: ^stream_id, streaming?: true} ->
        {:noreply,
         socket
         |> update(:assistant_reasoning, &((&1 || "") <> delta))
         |> append_streaming_delta(:reasoning, delta)}

      _stale_stream ->
        {:noreply, socket}
    end
  end

  def handle_info(
        {:openrouter_stream_event, stream_id, {:tool_call_started, tool_call}},
        socket
      ) do
    case socket.assigns do
      %{stream_id: ^stream_id, streaming?: true} ->
        {:noreply,
         socket
         |> update(:assistant_tool_calls, &(&1 ++ [AccountTurns.tool_call_view(tool_call)]))
         |> append_tool_block(AccountTurns.tool_call_view(tool_call))}

      _stale_stream ->
        {:noreply, socket}
    end
  end

  def handle_info({:account_chat_completed, stream_id, result}, socket) do
    case socket.assigns do
      %{stream_id: ^stream_id} ->
        {:noreply, socket |> reset_stream() |> restore_prompt(result)}

      _stale_run ->
        {:noreply, socket}
    end
  end

  def handle_info(:fleet_refresh, socket) do
    socket = refresh_fleet(socket)
    schedule_fleet_refresh(socket)
    {:noreply, socket}
  end

  def handle_info(
        {:openrouter_stream_event, stream_id, {:tool_call_completed, tool_result}},
        socket
      ) do
    update_streaming_tool(socket, stream_id, tool_result["call_id"], fn tool_call ->
      AccountTurns.apply_tool_event(tool_call, "tool_call_completed", tool_result)
    end)
  end

  def handle_info(
        {:openrouter_stream_event, stream_id, {:tool_call_failed, tool_result}},
        socket
      ) do
    update_streaming_tool(socket, stream_id, tool_result["call_id"], fn tool_call ->
      AccountTurns.apply_tool_event(tool_call, "tool_call_failed", tool_result)
    end)
  end

  # A turn taken elsewhere -- the account API, another tab -- moves the
  # transcript. A burst collapses into one re-read through the shared timer
  # rather than one repaint per turn.
  def handle_info({:account_turns_changed, conversation_id}, socket) do
    if conversation_id == socket.assigns.conversation.id,
      do: {:noreply, LiveRefresh.mark_stale(socket, :messages, &refresh_panel/2)},
      else: {:noreply, socket}
  end

  def handle_info(:live_refresh, socket),
    do: {:noreply, LiveRefresh.run(socket, &refresh_panel/2)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # A run still streaming contributes only its user message to this read, so
  # the panel is safe to re-read while this socket holds a stream of its own.
  defp refresh_panel(socket, :messages),
    do: assign_messages(socket, AccountTurns.list_messages(socket.assigns.current_user))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Chat"
      flush
    >
      <section id="chat-console" class="relative flex min-h-0 flex-1 flex-col bg-background">
        <div class="flex items-center gap-3 border-border border-b px-4 py-2">
          <span id="chat-console-model" class="font-medium text-sm">{@model_label}</span>
          <p id="chat-console-operator-notice" class="text-muted-foreground text-xs">
            Operator-only console. Prompts reach {@model_label} through the server.
          </p>
          <dl
            id="chat-console-token-list"
            class="ml-auto flex shrink-0 flex-wrap items-baseline justify-end gap-x-3 gap-y-1 text-xs"
            aria-label="Tokens this conversation used"
          >
            <div :if={@conversation_tokens == []} class="text-muted-foreground">
              No tokens yet
            </div>
            <div
              :for={{key, label, count} <- @conversation_tokens}
              id={"chat-console-token-#{key}"}
              class="flex items-baseline gap-1"
            >
              <dt class="text-muted-foreground">{label}</dt>
              <dd class="font-medium tabular-nums">{format_count(count)}</dd>
            </div>
          </dl>
        </div>

        <.fleet_panel
          :if={@fleet.boxes != [] or @fleet.queued != [] or @fleet.computers != []}
          fleet={@fleet}
          can_control={Fleet.owns_conversation?(@current_user, @conversation.id)}
        />

        <div class="flex min-h-0 flex-1 px-4">
          <.conversation id="chat-console-transcript" class="w-full">
            <.conversation_content class={[
              "mx-auto min-h-full w-full max-w-3xl px-0",
              if(@messages == [], do: "justify-center", else: "justify-end")
            ]}>
              <.conversation_empty_state :if={@messages == []} id="chat-console-empty">
                <div class="space-y-1">
                  <h3 class="font-medium text-sm">Drive {@model_label}</h3>
                  <p class="text-muted-foreground text-sm">
                    Send a prompt to open a turn. Only operators reach this console.
                  </p>
                </div>
                <.suggestions id="chat-console-suggestions" class="justify-center">
                  <.suggestion
                    :for={{prompt, index} <- Enum.with_index(@suggestions)}
                    id={"chat-console-suggestion-#{index}"}
                    suggestion={prompt}
                    phx-click="use_suggestion"
                    phx-value-prompt={prompt}
                  />
                </.suggestions>
              </.conversation_empty_state>

              <div :if={@messages != []} id="chat-console-exchange" class="space-y-5">
                <.message
                  :for={message <- @messages}
                  id={"chat-console-message-#{message.id}-#{message.role}"}
                  from={Atom.to_string(message.role)}
                  data-message-role={Atom.to_string(message.role)}
                >
                  <%= if message.role == :assistant do %>
                    <.assistant_block
                      :for={{block, index} <- Enum.with_index(message.blocks)}
                      id={"chat-console-block-#{message.id}-#{index}"}
                      block={block}
                    />
                    <p
                      :if={Map.get(message, :cancelled?)}
                      id={"chat-console-cancelled-#{message.id}"}
                      class="text-muted-foreground text-xs"
                      role="status"
                    >
                      You stopped this response.
                    </p>
                    <.message_content :if={message.error}>
                      <p id={"chat-console-error-#{message.id}"} role="alert">
                        {message.error}
                      </p>
                    </.message_content>
                    <.message_actions :if={Map.get(message, :retryable?) and not @streaming?}>
                      <.message_action
                        id={"chat-console-retry-#{message.id}"}
                        label="Retry this prompt"
                        tooltip="Retry this prompt"
                        phx-click="retry_message"
                        phx-value-prompt={prompt_for(@messages, message.id)}
                      >
                        <.icon name="regenerate" class="size-4" />
                      </.message_action>
                    </.message_actions>
                    <div
                      :if={message.completion}
                      class="flex flex-wrap items-center gap-3"
                    >
                      <p
                        id={"chat-console-response-metadata-#{message.id}"}
                        class="text-muted-foreground text-xs"
                      >
                        {provider_metadata(@model_label, message)}
                      </p>
                      <.context
                        :if={context_evidence(message)}
                        id={"chat-console-evidence-#{message.id}"}
                        used_tokens={context_evidence(message).used_tokens}
                        max_tokens={context_evidence(message).max_tokens}
                        input_tokens={message.usage.input}
                        output_tokens={message.usage.output}
                        reasoning_tokens={message.usage.reasoning}
                        cached_tokens={message.usage.cached}
                      />
                      <p
                        :if={Map.get(message, :usage)}
                        id={"chat-console-usage-#{message.id}"}
                        class="text-muted-foreground text-xs"
                      >
                        {usage_text(message.usage)}
                      </p>
                    </div>
                  <% else %>
                    <.message_content text={message.content} />
                  <% end %>
                </.message>

                <.message
                  :if={@streaming?}
                  id="chat-console-streaming-assistant-message"
                  from="assistant"
                >
                  <.assistant_block
                    :for={{block, index} <- Enum.with_index(@assistant_blocks)}
                    id={"chat-console-streaming-block-#{index}"}
                    block={block}
                    streaming
                  />
                </.message>
              </div>
            </.conversation_content>
          </.conversation>
        </div>

        <div id="chat-console-composer" class="chat-console-composer">
          <.prompt_input
            id="chat-console-form"
            for={@form}
            class="chat-console-composer__form"
            phx-submit="submit_message"
            clear_event="chat-console:clear"
            clear_on_submit
          >
            <.prompt_input_textarea
              field={@form[:message]}
              placeholder={"Message #{@model_label}"}
              aria-label={"Message #{@model_label}"}
              rows="1"
              maxlength="8000"
              autocomplete="off"
              phx-mounted={JS.focus()}
            />

            <.prompt_input_toolbar class="chat-console-composer__toolbar">
              <.input
                field={@form[:reasoning]}
                type="select"
                options={@reasoning_options}
                aria-label="Reasoning effort"
                class="chat-console-composer__reasoning"
                disabled={@streaming?}
              />
              <.prompt_input_tools class="ml-auto">
                <.prompt_input_submit
                  id="chat-console-submit"
                  status={if(@streaming?, do: :streaming, else: :ready)}
                  label={if(@streaming?, do: "Stop response", else: "Send message")}
                  on_stop="stop_response"
                  class="chat-console-composer__submit"
                />
              </.prompt_input_tools>
            </.prompt_input_toolbar>
          </.prompt_input>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :fleet, :map, required: true
  attr :can_control, :boolean, required: true

  defp fleet_panel(assigns) do
    ~H"""
    <section id="chat-console-fleet" class="border-border border-b bg-card/50 px-4 py-4">
      <div class="mx-auto w-full max-w-5xl space-y-4">
        <div class="flex flex-wrap items-baseline justify-between gap-2">
          <div>
            <h2 class="font-medium text-sm">Delegation fleet</h2>
            <p class="text-muted-foreground text-xs">
              Durable view of admitted Boxes, queued promises, and connected Computers.
            </p>
          </div>
          <p id="chat-console-fleet-cap" class="text-muted-foreground text-xs">
            Admitted {@fleet.admitted_count} of {@fleet.effective_cap}
          </p>
        </div>

        <div id="chat-console-fleet-boxes" class="grid gap-3 lg:grid-cols-2">
          <div
            :if={@fleet.boxes == []}
            id="chat-console-fleet-empty"
            class="rounded-lg border border-dashed border-border px-4 py-5 text-muted-foreground text-sm"
          >
            No admitted computers.
          </div>

          <article
            :for={box <- @fleet.boxes}
            id={"chat-console-fleet-box-#{box.id}"}
            class="space-y-3 rounded-lg border border-border bg-background p-4"
          >
            <header class="flex flex-wrap items-start justify-between gap-3">
              <div class="min-w-0">
                <h3 class="font-medium text-sm">{box.label}</h3>
                <p class="truncate font-mono text-muted-foreground text-xs" title={box.box_id}>
                  {box.box_id}
                </p>
              </div>
              <span class="badge" data-variant="dim">{box.state}</span>
            </header>

            <dl class="grid grid-cols-2 gap-3 text-xs sm:grid-cols-4">
              <div>
                <dt class="text-muted-foreground">Kind</dt>
                <dd class="mt-1 font-medium">Admitted</dd>
              </div>
              <div>
                <dt class="text-muted-foreground">Age</dt>
                <dd class="mt-1 font-medium">{box.age_seconds}s</dd>
              </div>
              <div :if={box.run}>
                <dt class="text-muted-foreground">Run</dt>
                <dd id={"chat-console-fleet-run-state-#{box.id}"} class="mt-1 font-medium">
                  {box.run.state}
                </dd>
              </div>
              <div :if={box.assignment}>
                <dt class="text-muted-foreground">Assignment</dt>
                <dd class="mt-1 font-medium">{box.assignment.state}</dd>
              </div>
            </dl>

            <div :if={box.run} id={"chat-console-fleet-run-#{box.id}"} class="space-y-2">
              <div class="flex items-center justify-between gap-2">
                <h4 class="font-medium text-xs">Run result</h4>
                <span :if={box.run.output_truncated?} class="text-muted-foreground text-xs">
                  Output truncated
                </span>
              </div>
              <pre
                id={"chat-console-fleet-output-#{box.id}"}
                class="max-h-48 overflow-auto rounded-md bg-muted/40 p-3 font-mono text-xs whitespace-pre-wrap"
              >{if(box.run.output == "", do: "No output yet.", else: box.run.output)}</pre>
              <p :if={box.run.failure_reason} class="text-destructive text-xs">
                {box.run.failure_reason}
              </p>
            </div>

            <dl
              :if={box.assignment}
              id={"chat-console-fleet-assignment-#{box.id}"}
              class="space-y-1 text-xs"
            >
              <div :if={box.assignment.branch} class="flex gap-2">
                <dt class="text-muted-foreground">Branch</dt>
                <dd class="font-mono">{box.assignment.branch}</dd>
              </div>
              <div :if={box.assignment.commit} class="flex gap-2">
                <dt class="text-muted-foreground">Commit</dt>
                <dd class="font-mono">{box.assignment.commit}</dd>
              </div>
              <div :if={box.assignment.failure_reason} class="flex gap-2">
                <dt class="text-muted-foreground">Failure</dt>
                <dd class="text-destructive">{box.assignment.failure_reason}</dd>
              </div>
            </dl>

            <div :if={@can_control and is_nil(box.stopped_at)} class="flex flex-wrap gap-2">
              <.button
                id={"chat-console-fleet-stop-#{box.id}"}
                type="button"
                variant={:ghost}
                tone={:danger}
                size={:sm}
                phx-click="stop_box"
                phx-value-box-id={box.label}
              >
                Stop computer
              </.button>
              <.button
                :if={box.run && not box.run.terminal?}
                id={"chat-console-fleet-cancel-#{box.id}"}
                type="button"
                variant={:ghost}
                tone={:danger}
                size={:sm}
                phx-click="cancel_box_run"
                phx-value-box-id={box.label}
                phx-value-run-id={box.run.id}
              >
                Cancel run
              </.button>
            </div>
          </article>
        </div>

        <div
          :if={@fleet.computers != []}
          id="chat-console-fleet-computers"
          class="grid gap-3 lg:grid-cols-2"
        >
          <article
            :for={computer <- @fleet.computers}
            id={"chat-console-fleet-computer-#{computer["computer_id"]}"}
            class="space-y-3 rounded-lg border border-border bg-background p-4"
          >
            <header class="flex flex-wrap items-start justify-between gap-3">
              <div class="min-w-0">
                <h3 class="font-medium text-sm">{computer["name"]}</h3>
                <p class="text-muted-foreground text-xs">Connected Computer</p>
              </div>
              <span class="badge" data-variant="dim">
                {if(computer["online"], do: "online", else: computer["status"])}
              </span>
            </header>
            <dl class="grid grid-cols-2 gap-3 text-xs sm:grid-cols-3">
              <div>
                <dt class="text-muted-foreground">Tier</dt>
                <dd class="mt-1 font-medium">{computer["tier"]}</dd>
              </div>
              <div>
                <dt class="text-muted-foreground">Roots</dt>
                <dd class="mt-1 font-medium">{length(computer["roots"] || [])}</dd>
              </div>
              <div :if={computer["delegation"]}>
                <dt class="text-muted-foreground">Delegation</dt>
                <dd class="mt-1 font-medium">{computer["delegation"]["state"]}</dd>
              </div>
            </dl>
            <div :if={computer["delegation"]} class="space-y-2">
              <p class="text-muted-foreground text-xs">
                Agent:
                <span class="font-medium text-foreground">{computer["delegation"]["agent_id"]}</span>
              </p>
              <pre
                id={"chat-console-fleet-computer-output-#{computer["computer_id"]}"}
                class="max-h-48 overflow-auto rounded-md bg-muted/40 p-3 font-mono text-xs whitespace-pre-wrap"
              >{computer["delegation"]["output"] || "No output yet."}</pre>
            </div>
          </article>
        </div>

        <div id="chat-console-fleet-queue" class="space-y-2">
          <div class="flex items-baseline justify-between gap-2">
            <h3 class="font-medium text-sm">Queued promises</h3>
            <span class="text-muted-foreground text-xs">{length(@fleet.queued)} queued</span>
          </div>
          <div
            :if={@fleet.queued == []}
            id="chat-console-fleet-queue-empty"
            class="text-muted-foreground text-xs"
          >
            No queued computers.
          </div>
          <article
            :for={item <- @fleet.queued}
            id={"chat-console-fleet-queued-#{item.id}"}
            class="flex flex-wrap items-baseline justify-between gap-2 rounded-md border border-dashed border-border px-3 py-2 text-xs"
          >
            <div class="flex min-w-0 items-baseline gap-2">
              <span class="font-medium">{item.label}</span>
              <span class="text-muted-foreground">Queued promise</span>
            </div>
            <div class="flex items-baseline gap-3">
              <span class="text-muted-foreground">{item.queue_reason}</span>
              <span class="text-muted-foreground">{item.age_seconds}s old</span>
            </div>
          </article>
          <p :if={@fleet.queued_truncated?} class="text-muted-foreground text-xs">
            Additional queued promises are not shown.
          </p>
        </div>
      </div>
    </section>
    """
  end

  # The console streams through the OpenRouter adapter. A configured streamer
  # replaces it, so a test can drive a turn without reaching a provider.
  defp submit_options(reasoning) do
    options = [reasoning: reasoning, subscriber: self()]

    case Application.get_env(:openagents, :chat_console_streamer) do
      streamer when is_function(streamer, 3) -> Keyword.put(options, :streamer, streamer)
      _adapter -> options
    end
  end

  defp composer_form(reasoning \\ "high", message \\ "") do
    to_form(%{"message" => message, "reasoning" => reasoning}, as: :chat)
  end

  defp current_reasoning(socket) do
    OpenRouter.reasoning_effort(Phoenix.HTML.Form.input_value(socket.assigns.form, :reasoning))
  end

  defp reset_stream(socket) do
    socket
    |> assign_messages(AccountTurns.list_messages(socket.assigns.current_user))
    |> refresh_fleet()
    |> assign(:assistant_response, nil)
    |> assign(:assistant_reasoning, nil)
    |> assign(:assistant_tool_calls, [])
    |> assign(:assistant_blocks, [])
    |> assign(:reasoning_started_at, nil)
    |> assign(:streaming?, false)
    |> assign(:stream_id, nil)
  end

  defp refresh_fleet(socket) do
    assign(
      socket,
      :fleet,
      Delegations.projection(socket.assigns.current_user, socket.assigns.conversation.id)
    )
  end

  defp schedule_fleet_refresh(socket) do
    Process.send_after(self(), :fleet_refresh, fleet_refresh_interval(socket.assigns.fleet))
    socket
  end

  defp fleet_refresh_interval(%{boxes: boxes, queued: queued, computers: computers}) do
    cond do
      queued != [] or Enum.any?(boxes, &moving_box?/1) or
          Enum.any?(computers, &moving_computer?/1) ->
        @fleet_fast_refresh_interval_ms

      boxes != [] or computers != [] ->
        @fleet_settled_refresh_interval_ms

      true ->
        @fleet_idle_refresh_interval_ms
    end
  end

  defp moving_box?(%{run: %{terminal?: false}}), do: true
  defp moving_box?(_box), do: false

  defp moving_computer?(%{"delegation" => %{"state" => state}}),
    do: state not in ~w(completed failed interrupted budget_exhausted cancelled)

  defp moving_computer?(_computer), do: false

  defp stop_box_error_message(:conversation_not_found), do: "You cannot stop this computer."
  defp stop_box_error_message(:not_found), do: "That computer is no longer available."
  defp stop_box_error_message(_reason), do: "The computer could not be stopped."

  defp cancel_box_run_error_message(:conversation_not_found),
    do: "You cannot cancel this run."

  defp cancel_box_run_error_message(:not_found), do: "That run is no longer available."
  defp cancel_box_run_error_message(_reason), do: "The run could not be canceled."

  # A failed turn keeps its prompt in the composer, so the operator can retry it
  # from either the composer or the failed message.
  defp restore_prompt(socket, {:error, _reason}) do
    assign(socket, :form, composer_form(current_reasoning(socket), socket.assigns.last_prompt))
  end

  defp restore_prompt(socket, _result), do: socket

  defp prompt_for(messages, id) do
    case Enum.find(messages, &(&1.id == id and &1.role == :user)) do
      %{content: content} -> content
      nil -> nil
    end
  end

  defp provider_metadata(model_label, message) do
    [
      model_label,
      message.provider_lane && "lane #{message.provider_lane}",
      message.latency_ms && "#{message.latency_ms} ms",
      message.request_id && "request #{message.request_id}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # The context meter needs a window the provider does not report, so it appears
  # only where the deployment states one.
  defp context_evidence(%{usage: %{total: total}}) when is_integer(total) do
    case Application.get_env(:openagents, :openrouter_context_window) do
      window when is_integer(window) and window > 0 -> %{used_tokens: total, max_tokens: window}
      _unset -> nil
    end
  end

  defp context_evidence(_message), do: nil

  # The top bar counts the whole conversation, so every assign of the transcript
  # recounts it and the running list never trails the messages it describes.
  defp assign_messages(socket, messages) do
    socket
    |> assign(:messages, messages)
    |> assign(:conversation_tokens, conversation_tokens(messages))
  end

  # `TokenUsage` decides what a set of turns reports, and the per-turn line
  # below asks it the same question about a set of one, so the running list and
  # the turns under it cannot disagree.
  defp conversation_tokens(messages) do
    usages = messages |> Enum.map(&Map.get(&1, :usage)) |> Enum.filter(&is_map/1)

    case TokenUsage.total(usages) do
      nil ->
        []

      {total, provenance} ->
        TokenUsage.counts(usages) ++ [{:total, total_label(provenance), total}]
    end
  end

  # A provider that leaves `total_tokens` out still reports the two sides of it,
  # and the label says so rather than presenting the sum as a reported total.
  defp total_label(:reported), do: "Total"
  defp total_label(:derived), do: "Total (input + output)"

  defp format_count(count) do
    count
    |> Integer.to_string()
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.intersperse(~c",")
    |> Enum.concat()
    |> Enum.reverse()
    |> List.to_string()
  end

  defp usage_text(usage) do
    [usage]
    |> TokenUsage.counts()
    |> Enum.map_join(" · ", fn {_kind, label, count} -> "#{label} #{count}" end)
  end

  defp submit_message(socket, message, reasoning) do
    case AccountTurns.submit(socket.assigns.current_user, message, submit_options(reasoning)) do
      {:ok, run} ->
        {:noreply,
         socket
         |> assign(:form, composer_form(reasoning))
         |> assign(:last_prompt, message)
         |> assign_messages(AccountTurns.list_messages(socket.assigns.current_user))
         |> assign(:assistant_response, "")
         |> assign(:assistant_reasoning, nil)
         |> assign(:assistant_tool_calls, [])
         |> assign(:assistant_blocks, [reasoning_block("")])
         |> assign(:reasoning_started_at, System.monotonic_time(:second))
         |> assign(:streaming?, true)
         |> assign(:stream_id, run["id"])
         |> push_event("chat-console:clear", %{})}

      {:error, reason} ->
        id = Ecto.UUID.generate()

        {:noreply,
         socket
         |> assign(:form, composer_form(reasoning, message))
         |> assign_messages(
           socket.assigns.messages ++ [user_message(id, message), failed_message(id, reason)]
         )}
    end
  end

  defp failed_message(id, reason),
    do: %{
      id: id,
      role: :assistant,
      content: "",
      completion: nil,
      error: error_message(reason),
      error_code: error_code(reason),
      retryable?: AccountTurns.retryable_error_code?(error_code(reason)),
      cancelled?: false,
      usage: nil,
      provider_lane: nil,
      request_id: nil,
      latency_ms: nil,
      history?: false,
      provider_message_id: nil,
      provider_status: nil,
      provider_reasoning_items: nil,
      reasoning: nil,
      reasoning_duration: nil,
      tool_calls: [],
      blocks: []
    }

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({:provider_error, code, _detail}) when is_binary(code), do: code
  defp error_code(_reason), do: "provider_error"

  defp user_message(id, content),
    do: %{
      id: id,
      role: :user,
      content: content,
      completion: nil,
      error: nil,
      history?: true,
      tool_calls: [],
      blocks: []
    }

  defp error_message(:missing_api_key), do: "OpenRouter is not configured for this environment."
  defp error_message(:rate_limited), do: "OpenRouter is rate-limited. Try again later."

  defp error_message({:provider_error, "authentication", _detail}),
    do: "OpenRouter rejected this request because its API key is invalid or unavailable."

  defp error_message({:provider_error, "invalid_prompt", detail}),
    do: provider_error_message("OpenRouter rejected this request because it is invalid.", detail)

  defp error_message({:provider_error, "image_content_policy_violation", _detail}),
    do: "OpenRouter blocked this request because it violated its content policy."

  defp error_message({:provider_error, "server_error", _detail}),
    do: "OpenRouter is unavailable right now. Try again later."

  defp error_message({:provider_error, code, detail}),
    do: provider_error_message("OpenRouter returned an error (#{code}).", detail)

  defp error_message(_reason), do: "OpenRouter could not complete that message. Try again later."

  defp provider_error_message(summary, nil), do: summary
  defp provider_error_message(summary, detail), do: "#{summary} #{detail}"

  attr :id, :string, required: true
  attr :tool_call, :map, required: true
  attr :open, :boolean, default: false

  defp tool_call_component(assigns) do
    ~H"""
    <.tool id={@id} open={@open || @tool_call.state != "output-available"}>
      <.tool_header
        type={"tool-#{@tool_call.name}"}
        title={@tool_call.name}
        state={@tool_call.state}
      />
      <.tool_content id={"#{@id}-content"}>
        <dl
          id={"#{@id}-metadata"}
          class="grid gap-x-6 gap-y-3 border-b border-border pb-4 sm:grid-cols-3"
        >
          <div>
            <dt class="text-xs uppercase tracking-wide text-muted-foreground">Status</dt>
            <dd class="mt-1 font-medium text-sm">{@tool_call.status}</dd>
          </div>
          <div :if={@tool_call.workspace_label}>
            <dt class="text-xs uppercase tracking-wide text-muted-foreground">Workspace</dt>
            <dd class="mt-1 truncate font-mono text-sm" title={@tool_call.workspace_label}>
              {@tool_call.workspace_label}
            </dd>
          </div>
          <div :if={is_integer(@tool_call.duration_ms)}>
            <dt class="text-xs uppercase tracking-wide text-muted-foreground">Duration</dt>
            <dd class="mt-1 font-medium text-sm">{format_duration(@tool_call.duration_ms)}</dd>
          </div>
          <div :if={@tool_call.error_code}>
            <dt class="text-xs uppercase tracking-wide text-muted-foreground">Error code</dt>
            <dd class="mt-1 font-mono text-sm text-destructive">{@tool_call.error_code}</dd>
          </div>
        </dl>
        <.tool_input id={"#{@id}-input"} input={@tool_call.arguments} />
        <.tool_output
          id={"#{@id}-output"}
          output={@tool_call.output}
          error_text={@tool_call.error}
        />
        <div :if={@tool_call.receipt_refs != []} id={"#{@id}-receipts"} class="space-y-2">
          <h4 class="font-medium text-muted-foreground text-xs uppercase tracking-wide">
            Receipts
          </h4>
          <ul class="space-y-1 rounded-md bg-muted/50 p-4 font-mono text-xs">
            <li :for={receipt <- @tool_call.receipt_refs}>{format_receipt(receipt)}</li>
          </ul>
        </div>
      </.tool_content>
    </.tool>
    """
  end

  attr :id, :string, required: true
  attr :block, :map, required: true
  attr :streaming, :boolean, default: false

  defp assistant_block(assigns) do
    ~H"""
    <%= case @block.type do %>
      <% :reasoning -> %>
        <.reasoning id={@id} open={@streaming && is_nil(@block.duration)}>
          <.reasoning_trigger
            streaming={@streaming && is_nil(@block.duration)}
            duration={@block.duration || 0}
          />
          <.reasoning_content
            :if={@block.text != ""}
            text={@block.text}
            streaming={@streaming && is_nil(@block.duration)}
          />
        </.reasoning>
      <% :tool -> %>
        <.tool_call_component id={@id} tool_call={@block.tool_call} open />
      <% :content -> %>
        <.message_content id={@id} text={@block.text} streaming={@streaming} />
    <% end %>
    """
  end

  defp update_streaming_tool(socket, stream_id, call_id, update_tool) do
    case socket.assigns do
      %{stream_id: ^stream_id, streaming?: true} ->
        {:noreply,
         socket
         |> update(:assistant_tool_calls, &update_tool_call(&1, call_id, update_tool))
         |> update(:assistant_blocks, fn blocks ->
           Enum.map(blocks, fn
             %{type: :tool, tool_call: %{call_id: ^call_id} = tool_call} = block ->
               %{block | tool_call: update_tool.(tool_call)}

             block ->
               block
           end)
         end)}

      _stale_stream ->
        {:noreply, socket}
    end
  end

  defp format_duration(duration_ms) when duration_ms < 1_000, do: "#{duration_ms} ms"
  defp format_duration(duration_ms), do: "#{Float.round(duration_ms / 1_000, 1)} s"
  defp format_receipt(receipt) when is_binary(receipt), do: receipt
  defp format_receipt(receipt), do: Jason.encode!(receipt)

  defp update_tool_call(tool_calls, call_id, update_tool) do
    Enum.map(tool_calls, fn
      %{call_id: ^call_id} = tool_call -> update_tool.(tool_call)
      tool_call -> tool_call
    end)
  end

  defp append_streaming_delta(socket, type, delta) do
    update(socket, :assistant_blocks, fn blocks ->
      case List.last(blocks) do
        %{type: ^type} = block ->
          List.replace_at(blocks, -1, %{block | text: block.text <> delta})

        _other ->
          finalize_assistant_blocks(blocks) ++ [streaming_block(type, delta)]
      end
    end)
  end

  defp append_tool_block(socket, tool_call) do
    update(socket, :assistant_blocks, fn blocks ->
      finalize_assistant_blocks(blocks) ++ [%{type: :tool, tool_call: tool_call}]
    end)
  end

  defp streaming_block(:reasoning, text), do: reasoning_block(text)
  defp streaming_block(:content, text), do: %{type: :content, text: text}

  defp reasoning_block(text) do
    %{
      type: :reasoning,
      text: text,
      started_at: System.monotonic_time(:second),
      duration: nil
    }
  end

  defp finalize_assistant_blocks(blocks) do
    blocks
    |> Enum.map(fn
      %{type: :reasoning, duration: nil} = block ->
        %{block | duration: max(System.monotonic_time(:second) - block.started_at, 1)}

      block ->
        block
    end)
    |> Enum.reject(&(&1.type == :reasoning and &1.text == ""))
  end
end
