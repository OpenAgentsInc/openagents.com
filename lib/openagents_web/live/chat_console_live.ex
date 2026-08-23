defmodule OpenAgentsWeb.ChatConsoleLive do
  @moduledoc """
  The Ox Alpha console, reachable at `/chat` by operators only.

  The console drives one Ox Alpha conversation per operator account. It sends
  every request to OpenRouter from the server, so the provider credential never
  reaches the browser, and it prefers the Responses API, using chat completions
  only when a provider cannot serve Responses.

  It shares the AI Elements components with Sarah's transcript at `/sarah` and
  shares none of her state: no persona, no voice, no work queue, and no
  conversation of hers. The model is fixed, so there is no model picker, and
  reasoning, tool calls, usage, and provider lane appear only when the provider
  reports them.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Chat.{AccountTurns, OpenRouter}

  @suggestions [
    "Summarize what the Ox Alpha stress fleet measures today.",
    "Draft a checklist for a cloud-computer stress run.",
    "Explain the difference between a push and a deploy here.",
    "Write a short status update for the current fleet work."
  ]

  @token_kinds [input: "Input", output: "Output", reasoning: "Reasoning", cached: "Cached"]

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
    messages = AccountTurns.list_messages(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:page_title, "Chat")
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
     |> assign(:stream_id, nil)}
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

  def handle_info(_message, socket), do: {:noreply, socket}

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
    |> assign(:assistant_response, nil)
    |> assign(:assistant_reasoning, nil)
    |> assign(:assistant_tool_calls, [])
    |> assign(:assistant_blocks, [])
    |> assign(:reasoning_started_at, nil)
    |> assign(:streaming?, false)
    |> assign(:stream_id, nil)
  end

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

  # Provider-reported counts only, summed across the turns that reported them. A
  # kind no turn reported stays off the list instead of reading as a zero.
  defp conversation_tokens(messages) do
    usages = messages |> Enum.map(&Map.get(&1, :usage)) |> Enum.filter(&is_map/1)

    case usages do
      [] ->
        []

      usages ->
        kinds =
          for {key, label} <- @token_kinds,
              count = sum_tokens(usages, key),
              do: {key, label, count}

        kinds ++ [{:total, "Total", conversation_total(usages)}]
    end
  end

  defp sum_tokens(usages, key) do
    case usages |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      counts -> Enum.sum(counts)
    end
  end

  defp conversation_total(usages), do: Enum.sum(Enum.map(usages, &turn_total/1))

  # A provider that leaves `total_tokens` out still reports the two sides of it.
  defp turn_total(%{total: total}) when is_integer(total), do: total
  defp turn_total(usage), do: (usage.input || 0) + (usage.output || 0)

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
    [
      usage.input && "Input #{usage.input}",
      usage.output && "Output #{usage.output}",
      usage.reasoning && "Reasoning #{usage.reasoning}",
      usage.cached && "Cached #{usage.cached}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
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
