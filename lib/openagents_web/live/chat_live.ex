defmodule OpenAgentsWeb.ChatLive do
  @moduledoc """
  Mock chat LiveView. Renders a full chat interface with fake data while
  the real inference, memory, and voice layers are wired in.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Chat

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:messages, Chat.messages())
     |> assign(:form, composer_form())}
  end

  @impl true
  def handle_event("send_message", %{"chat" => %{"content" => content}}, socket) do
    trimmed = String.trim(content)

    if trimmed == "" do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:messages, socket.assigns.messages ++ Chat.fake_reply(trimmed))
       |> assign(:form, composer_form())}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      wide
      title="Chat"
      subtitle="Mock inference and voice pipeline"
    >
      <div
        id="chat-app"
        class="h-[calc(100%-2rem)] w-full flex flex-col border border-base-300 rounded-lg overflow-hidden"
      >
        <div
          id="transcript"
          class="chat-transcript flex-1 overflow-y-auto p-4 space-y-6"
        >
          <%= for message <- @messages do %>
            <.message_row message={message} id={message.id} />
          <% end %>
        </div>

        <.composer_stack form={@form} />
      </div>
    </Layouts.app>
    """
  end

  attr :message, :map, required: true
  attr :id, :string, required: true

  defp message_row(assigns) do
    ~H"""
    <article
      id={@id}
      class={[
        "message-row",
        "message-row--#{@message.role}"
      ]}
    >
      <div class="message-body">
        <div
          :if={@message.inserted_at}
          class="message-time"
        >
          {Calendar.strftime(@message.inserted_at, "%H:%M")}
        </div>
        <p class={[
          "message-content",
          @message.role == "user" && "message-bubble"
        ]}>
          {@message.content}
        </p>
      </div>
    </article>
    """
  end

  attr :form, :any, required: true

  defp composer_stack(assigns) do
    ~H"""
    <.form
      for={@form}
      id="chat-form"
      phx-submit="send_message"
      class="composer"
    >
      <div class="composer-card">
        <div class="composer-grid">
          <.input
            field={@form[:content]}
            type="textarea"
            class="composer-input"
            placeholder="Message OpenAgents..."
            aria-label="Message OpenAgents..."
            rows="1"
          />
          <div class="composer-trailing">
            <.button
              type="submit"
              class="send-action"
              aria-label="Send"
            >
              <.icon name="arrow-up" class="size-5" />
            </.button>
          </div>
        </div>
      </div>
    </.form>
    """
  end

  defp composer_form do
    to_form(%{"content" => ""}, as: :chat)
  end
end
