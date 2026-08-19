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
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div
        id="chat-app"
        class="h-full flex flex-col border border-base-300 rounded-lg overflow-hidden"
      >
        <header class="p-4 border-b border-base-300 flex items-center justify-between">
          <div class="flex items-center gap-3">
            <.icon name="hero-sparkles" class="size-6 text-primary" />
            <h1 class="font-semibold">Sarah</h1>
            <span class="badge badge-sm badge-ghost">Mock</span>
          </div>
          <div class="flex items-center gap-2 text-sm text-base-content/70">
            <.icon name="hero-cpu-chip" class="size-4" />
            <span>Core chat and inference logic in this repo</span>
          </div>
        </header>

        <div
          id="transcript"
          class="flex-1 overflow-y-auto p-4 space-y-4"
        >
          <%= for message <- @messages do %>
            <.message_row message={message} id={message.id} />
          <% end %>
        </div>

        <.form
          for={@form}
          id="chat-form"
          phx-submit="send_message"
          class="p-4 border-t border-base-300"
        >
          <div class="flex items-end gap-2">
            <.input
              field={@form[:content]}
              type="textarea"
              placeholder="Message Sarah..."
              class="flex-1"
              rows="2"
            />
            <.button type="submit" variant="primary" class="btn-md">
              Send
            </.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  defp message_row(assigns) do
    ~H"""
    <div id={@id} class={["chat", @message.role == "user" && "chat-end"]}>
      <div class="chat-image avatar">
        <div class="w-10 rounded-full bg-base-300 flex items-center justify-center">
          <.icon name={avatar_icon(@message.role)} class="size-6" />
        </div>
      </div>
      <div class="chat-header">
        <span class="text-sm font-semibold capitalize">{@message.role}</span>
      </div>
      <div class={[
        "chat-bubble",
        @message.role == "user" && "chat-bubble-primary"
      ]}>
        {@message.content}
      </div>
    </div>
    """
  end

  defp avatar_icon("user"), do: "hero-user"
  defp avatar_icon(_), do: "hero-sparkles"

  defp composer_form do
    to_form(%{"content" => ""}, as: :chat)
  end
end
