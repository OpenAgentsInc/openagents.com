defmodule OpenAgentsWeb.ChatPlaceholderLive do
  @moduledoc """
  A placeholder for the upcoming chat surface, reachable at `/chat` by
  operators only.

  The real product has not landed; this page exists so the route, its
  authority gate, and its sidebar row are in place before the surface is.
  """

  use OpenAgentsWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Chat")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Chat"
    >
      <div id="chat-placeholder">
        <.empty id="chat-placeholder-empty" title="Chat is being built">
          <p>
            This will become OpenAgents' new chat surface. For now it is an
            operator preview with nothing to operate on.
          </p>
          <p>
            The Sarah conversation keeps its home at <.link navigate={~p"/sarah"} class="underline">/sarah</.link>.
          </p>
        </.empty>
      </div>
    </Layouts.app>
    """
  end
end
