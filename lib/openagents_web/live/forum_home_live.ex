defmodule OpenAgentsWeb.ForumHomeLive do
  @moduledoc "The forum entry point: every listed board with its counts."
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Forum

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:forums, Forum.list_public_forums())}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">Forum</h1>
      </div>

      <%= if @forums == [] do %>
        <div class="alert" data-variant="info" role="status">
          <.icon name="info-circle" class="size-5" />
          <section>No boards yet.</section>
        </div>
      <% else %>
        <div class="space-y-3">
          <%= for forum <- @forums do %>
            <.link
              navigate={~p"/forum/f/#{forum.slug}"}
              class="card !m-0 block hover:border-foreground/20 transition-colors"
            >
              <div class="flex items-center justify-between gap-2">
                <h2 class="text-lg font-semibold">{forum.title}</h2>
                <span class="badge" data-variant="dim">{forum.topic_count} topics</span>
              </div>
              <%= if forum.description do %>
                <p class="text-sm text-muted-foreground mt-1">{forum.description}</p>
              <% end %>
            </.link>
          <% end %>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
