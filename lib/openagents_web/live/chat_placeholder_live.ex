defmodule OpenAgentsWeb.ChatPlaceholderLive do
  @moduledoc """
  A local chat preview, reachable at `/chat` by operators only.

  The preview sends requests to OpenRouter from the server. It prefers the
  Responses API and uses Chat Completions only when a provider cannot serve
  that API.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Chat.OpenRouter

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
    only: [reasoning: 1, reasoning_trigger: 1, reasoning_content: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Chat")
     |> assign(:form, composer_form())
     |> assign(:reasoning_options, @reasoning_options)
     |> assign(:messages, [])
     |> assign(:assistant_response, nil)
     |> assign(:assistant_reasoning, nil)
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
        {:noreply, update(socket, :assistant_response, &(&1 <> delta))}

      _stale_stream ->
        {:noreply, socket}
    end
  end

  def handle_info({:openrouter_stream_event, stream_id, {:reasoning_delta, delta}}, socket) do
    case socket.assigns do
      %{stream_id: ^stream_id, streaming?: true} ->
        {:noreply, update(socket, :assistant_reasoning, &((&1 || "") <> delta))}

      _stale_stream ->
        {:noreply, socket}
    end
  end

  def handle_info(
        {task_ref, {:ok, completion}},
        %{assigns: %{stream_task_ref: task_ref}} = socket
      ) do
    Process.demonitor(task_ref, [:flush])

    assistant_content = completion["assistant_content"] || socket.assigns.assistant_response
    reasoning = completion["reasoning_summary"] || socket.assigns.assistant_reasoning

    {:noreply,
     socket
     |> append_assistant_message(
       socket.assigns.stream_id,
       assistant_content,
       completion,
       nil,
       reasoning,
       reasoning_duration(socket)
     )
     |> assign(:assistant_response, nil)
     |> assign(:assistant_reasoning, nil)
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
       error_message(reason)
     )
     |> assign(:assistant_response, nil)
     |> assign(:assistant_reasoning, nil)
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
       error_message(:provider_unavailable)
     )
     |> assign(:assistant_response, nil)
     |> assign(:assistant_reasoning, nil)
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
        <div class="flex min-h-0 flex-1 px-4 pb-44 pt-6">
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
                  <.reasoning
                    :if={message.role == :assistant and message.reasoning}
                    id={"chat-placeholder-reasoning-#{message.id}"}
                    open={false}
                  >
                    <.reasoning_trigger duration={message.reasoning_duration} />
                    <.reasoning_content text={message.reasoning} />
                  </.reasoning>
                  <.message_content text={message.content}>
                    <p :if={message.error} id={"chat-placeholder-error-#{message.id}"} role="status">
                      {message.error}
                    </p>
                    <p
                      :if={message.completion}
                      id={"chat-placeholder-response-metadata-#{message.id}"}
                      class="text-muted-foreground text-xs"
                    >
                      OpenRouter · {message.completion["object"]} · {message.completion["model"]}
                    </p>
                  </.message_content>
                </.message>

                <.message
                  :if={@streaming?}
                  id="chat-placeholder-streaming-assistant-message"
                  from="assistant"
                >
                  <.reasoning
                    :if={@streaming?}
                    id="chat-placeholder-streaming-reasoning"
                    open={true}
                  >
                    <.reasoning_trigger streaming={true} duration={0} />
                    <.reasoning_content
                      :if={@assistant_reasoning}
                      text={@assistant_reasoning}
                      streaming
                    />
                  </.reasoning>
                  <.message_content
                    id="chat-placeholder-response"
                    text={@assistant_response}
                    streaming={@streaming?}
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

  defp local_chat_request(messages, message, reasoning) do
    %{
      "model" => OpenRouter.default_model(),
      "models" => ["openrouter/free"],
      "reasoning" => reasoning,
      "messages" =>
        Enum.map(messages, &provider_message/1) ++ [%{"role" => "user", "content" => message}]
    }
  end

  defp submit_message(socket, message, reasoning) do
    stream_id = System.unique_integer([:positive, :monotonic])
    owner = self()

    request =
      local_chat_request(
        Enum.filter(socket.assigns.messages, fn message -> message.history? end),
        message,
        reasoning
      )

    task =
      Task.Supervisor.async_nolink(OpenAgents.ProviderTaskSupervisor, fn ->
        OpenRouter.stream(request, fn event ->
          send(owner, {:openrouter_stream_event, stream_id, event})
        end)
      end)

    {:noreply,
     socket
     |> assign(:form, composer_form(reasoning))
     |> update(:messages, &(&1 ++ [user_message(stream_id, message)]))
     |> assign(:assistant_response, "")
     |> assign(:assistant_reasoning, nil)
     |> assign(:reasoning_started_at, System.monotonic_time(:second))
     |> assign(:streaming?, true)
     |> assign(:stream_task_ref, task.ref)
     |> assign(:stream_id, stream_id)
     |> push_event("chat-preview:clear", %{})}
  end

  defp user_message(id, content),
    do: %{id: id, role: :user, content: content, completion: nil, error: nil, history?: true}

  defp append_assistant_message(socket, id, content, completion, error) do
    append_assistant_message(socket, id, content, completion, error, nil, nil)
  end

  defp append_assistant_message(
         socket,
         id,
         content,
         completion,
         error,
         reasoning,
         reasoning_duration
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
      reasoning_duration: reasoning_duration
    }

    update(socket, :messages, &(&1 ++ [assistant]))
  end

  defp provider_message(%{role: :assistant} = message) do
    %{"role" => "assistant", "content" => message.content}
    |> maybe_put_provider_message_id(message.provider_message_id)
    |> maybe_put_provider_status(message.provider_status)
    |> maybe_put_provider_reasoning_items(message.provider_reasoning_items)
  end

  defp provider_message(%{role: role, content: content}),
    do: %{"role" => Atom.to_string(role), "content" => content}

  defp maybe_put_provider_message_id(message, id) when is_binary(id),
    do: Map.put(message, "id", id)

  defp maybe_put_provider_message_id(message, _id), do: message

  defp maybe_put_provider_status(message, status) when is_binary(status),
    do: Map.put(message, "status", status)

  defp maybe_put_provider_status(message, _status), do: message

  defp maybe_put_provider_reasoning_items(message, items) when is_list(items) and items != [],
    do: Map.put(message, "reasoning_items", items)

  defp maybe_put_provider_reasoning_items(message, _items), do: message

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
end
