defmodule OpenAgentsWeb.ChatPlaceholderLive do
  @moduledoc """
  A local chat preview, reachable at `/chat` by operators only.

  The preview sends requests to OpenRouter from the server. It prefers the
  Responses API and uses Chat Completions only when a provider cannot serve
  that API.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Chat.{AccountTurns, OpenRouter}

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
      message_content: 1
    ]

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
     |> assign(:messages, messages)
     |> assign(:assistant_response, nil)
     |> assign(:assistant_reasoning, nil)
     |> assign(:assistant_tool_calls, [])
     |> assign(:assistant_blocks, [])
     |> assign(:reasoning_started_at, nil)
     |> assign(:streaming?, false)
     |> assign(:stream_task_ref, nil)
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

  def handle_info({:account_chat_completed, stream_id, _result}, socket) do
    case socket.assigns do
      %{stream_id: ^stream_id} ->
        {:noreply,
         socket
         |> assign(:messages, AccountTurns.list_messages(socket.assigns.current_user))
         |> assign(:assistant_response, nil)
         |> assign(:assistant_reasoning, nil)
         |> assign(:assistant_tool_calls, [])
         |> assign(:assistant_blocks, [])
         |> assign(:reasoning_started_at, nil)
         |> assign(:streaming?, false)
         |> assign(:stream_task_ref, nil)
         |> assign(:stream_id, nil)}

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

  def handle_info(
        {task_ref, {:ok, completion}},
        %{assigns: %{stream_task_ref: task_ref}} = socket
      ) do
    Process.demonitor(task_ref, [:flush])

    assistant_content = completion["assistant_content"] || socket.assigns.assistant_response
    reasoning = completion["reasoning_summary"] || socket.assigns.assistant_reasoning

    assistant_blocks =
      reconcile_assistant_blocks(socket.assigns.assistant_blocks, assistant_content, reasoning)

    {:noreply,
     socket
     |> append_assistant_message(
       socket.assigns.stream_id,
       assistant_content,
       completion,
       nil,
       reasoning,
       reasoning_duration(socket),
       socket.assigns.assistant_tool_calls,
       assistant_blocks
     )
     |> assign(:assistant_response, nil)
     |> assign(:assistant_reasoning, nil)
     |> assign(:assistant_tool_calls, [])
     |> assign(:assistant_blocks, [])
     |> assign(:reasoning_started_at, nil)
     |> assign(:streaming?, false)
     |> assign(:stream_task_ref, nil)
     |> assign(:stream_id, nil)}
  end

  def handle_info({task_ref, {:error, reason}}, %{assigns: %{stream_task_ref: task_ref}} = socket) do
    Process.demonitor(task_ref, [:flush])

    {:noreply,
     socket
     |> append_assistant_message(
       socket.assigns.stream_id,
       socket.assigns.assistant_response,
       nil,
       error_message(reason),
       socket.assigns.assistant_reasoning,
       reasoning_duration(socket),
       socket.assigns.assistant_tool_calls,
       finalize_assistant_blocks(socket.assigns.assistant_blocks)
     )
     |> assign(:assistant_response, nil)
     |> assign(:assistant_reasoning, nil)
     |> assign(:assistant_tool_calls, [])
     |> assign(:assistant_blocks, [])
     |> assign(:reasoning_started_at, nil)
     |> assign(:streaming?, false)
     |> assign(:stream_task_ref, nil)
     |> assign(:stream_id, nil)}
  end

  def handle_info(
        {:DOWN, task_ref, :process, _pid, _reason},
        %{assigns: %{stream_task_ref: task_ref}} = socket
      ) do
    {:noreply,
     socket
     |> append_assistant_message(
       socket.assigns.stream_id,
       socket.assigns.assistant_response,
       nil,
       error_message(:provider_unavailable),
       socket.assigns.assistant_reasoning,
       reasoning_duration(socket),
       socket.assigns.assistant_tool_calls,
       finalize_assistant_blocks(socket.assigns.assistant_blocks)
     )
     |> assign(:assistant_response, nil)
     |> assign(:assistant_reasoning, nil)
     |> assign(:assistant_tool_calls, [])
     |> assign(:assistant_blocks, [])
     |> assign(:reasoning_started_at, nil)
     |> assign(:streaming?, false)
     |> assign(:stream_task_ref, nil)
     |> assign(:stream_id, nil)}
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
      <section id="chat-placeholder" class="relative flex min-h-0 flex-1 flex-col bg-background">
        <div class="flex min-h-0 flex-1 px-4">
          <.conversation
            id="chat-placeholder-transcript"
            class="w-full"
            scroll_button={false}
          >
            <.conversation_content class={[
              "mx-auto min-h-full w-full max-w-3xl px-0",
              if(@messages == [], do: "justify-center", else: "justify-end")
            ]}>
              <.conversation_empty_state
                :if={@messages == []}
                id="chat-placeholder-empty"
                title="Start a conversation"
                description="Send a message to start a conversation."
              />

              <div :if={@messages != []} id="chat-placeholder-exchange" class="space-y-5">
                <.message
                  :for={message <- @messages}
                  id={"chat-placeholder-message-#{message.id}-#{message.role}"}
                  from={Atom.to_string(message.role)}
                  data-message-role={Atom.to_string(message.role)}
                >
                  <%= if message.role == :assistant do %>
                    <.assistant_block
                      :for={{block, index} <- Enum.with_index(message.blocks)}
                      id={"chat-placeholder-block-#{message.id}-#{index}"}
                      block={block}
                    />
                    <.message_content :if={message.error}>
                      <p id={"chat-placeholder-error-#{message.id}"} role="status">
                        {message.error}
                      </p>
                    </.message_content>
                    <p
                      :if={message.completion}
                      id={"chat-placeholder-response-metadata-#{message.id}"}
                      class="text-muted-foreground text-xs"
                    >
                      OpenRouter · {message.completion["object"]} · {message.completion["model"]}
                    </p>
                  <% else %>
                    <.message_content text={message.content} />
                  <% end %>
                </.message>

                <.message
                  :if={@streaming?}
                  id="chat-placeholder-streaming-assistant-message"
                  from="assistant"
                >
                  <.assistant_block
                    :for={{block, index} <- Enum.with_index(@assistant_blocks)}
                    id={"chat-placeholder-streaming-block-#{index}"}
                    block={block}
                    streaming
                  />
                </.message>
              </div>
            </.conversation_content>
          </.conversation>
        </div>

        <div id="chat-placeholder-composer" class="chat-placeholder-composer">
          <.prompt_input
            id="chat-placeholder-form"
            for={@form}
            class="chat-placeholder-composer__form"
            phx-submit="submit_message"
            clear_event="chat-preview:clear"
            clear_on_submit
          >
            <.prompt_input_textarea
              field={@form[:message]}
              placeholder="Message OpenAgents"
              aria-label="Message OpenAgents"
              rows="1"
              maxlength="8000"
              autocomplete="off"
              phx-mounted={JS.focus()}
            />

            <.prompt_input_toolbar class="chat-placeholder-composer__toolbar">
              <.input
                field={@form[:reasoning]}
                type="select"
                options={@reasoning_options}
                aria-label="Reasoning effort"
                class="chat-placeholder-composer__reasoning"
                disabled={@streaming?}
              />
              <.prompt_input_tools class="ml-auto">
                <.prompt_input_submit
                  id="chat-placeholder-submit"
                  status={if(@streaming?, do: :submitted, else: :ready)}
                  label="Send message"
                  class="chat-placeholder-composer__submit"
                  disabled={@streaming?}
                />
              </.prompt_input_tools>
            </.prompt_input_toolbar>
          </.prompt_input>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp composer_form(reasoning \\ "high") do
    to_form(%{"message" => "", "reasoning" => reasoning}, as: :chat)
  end

  defp submit_message(socket, message, reasoning) do
    case AccountTurns.submit(socket.assigns.current_user, message,
           reasoning: reasoning,
           subscriber: self()
         ) do
      {:ok, run} ->
        {:noreply,
         socket
         |> assign(:form, composer_form(reasoning))
         |> assign(:messages, AccountTurns.list_messages(socket.assigns.current_user))
         |> assign(:assistant_response, "")
         |> assign(:assistant_reasoning, nil)
         |> assign(:assistant_tool_calls, [])
         |> assign(:assistant_blocks, [reasoning_block("")])
         |> assign(:reasoning_started_at, System.monotonic_time(:second))
         |> assign(:streaming?, true)
         |> assign(:stream_task_ref, nil)
         |> assign(:stream_id, run["id"])
         |> push_event("chat-preview:clear", %{})}

      {:error, reason} ->
        {:noreply,
         socket
         |> update(:messages, fn messages ->
           messages ++
             [
               user_message(Ecto.UUID.generate(), message),
               %{
                 id: Ecto.UUID.generate(),
                 role: :assistant,
                 content: "",
                 completion: nil,
                 error: error_message(reason),
                 history?: false,
                 provider_message_id: nil,
                 provider_status: nil,
                 provider_reasoning_items: nil,
                 reasoning: nil,
                 reasoning_duration: nil,
                 tool_calls: [],
                 blocks: []
               }
             ]
         end)}
    end
  end

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

  defp append_assistant_message(
         socket,
         id,
         content,
         completion,
         error,
         reasoning,
         reasoning_duration,
         tool_calls,
         blocks
       ) do
    assistant = %{
      id: id,
      role: :assistant,
      content: content,
      completion: completion,
      error: error,
      history?: is_nil(error),
      provider_message_id: completion && completion["assistant_message_id"],
      provider_status: if(completion && completion["assistant_message_id"], do: "completed"),
      provider_reasoning_items: completion && completion["reasoning_items"],
      reasoning: reasoning,
      reasoning_duration: reasoning_duration,
      tool_calls: tool_calls,
      blocks: blocks
    }

    update(socket, :messages, &(&1 ++ [assistant]))
  end

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

  defp reasoning_duration(%{assigns: %{reasoning_started_at: started_at}})
       when is_integer(started_at) do
    max(System.monotonic_time(:second) - started_at, 1)
  end

  defp reasoning_duration(_socket), do: nil

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

  defp reconcile_assistant_blocks(blocks, content, reasoning) do
    blocks = finalize_assistant_blocks(blocks)

    blocks =
      if Enum.any?(blocks, &(&1.type == :reasoning)) or not is_binary(reasoning) or
           reasoning == "" do
        blocks
      else
        [%{reasoning_block(reasoning) | duration: 1} | blocks]
      end

    case Enum.find_index(Enum.reverse(blocks), &(&1.type == :content)) do
      nil when is_binary(content) and content != "" ->
        blocks ++ [%{type: :content, text: content}]

      nil ->
        blocks

      reversed_index when is_binary(content) ->
        index = length(blocks) - reversed_index - 1
        List.update_at(blocks, index, &%{&1 | text: content})

      _index ->
        blocks
    end
  end
end
