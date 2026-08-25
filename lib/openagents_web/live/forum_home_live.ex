defmodule OpenAgentsWeb.ForumHomeLive do
  @moduledoc """
  The forum entry point: every listed board with its counts.

  The counts are current. A topic started anywhere moves the board it was
  started on, and because the list is ordered by topic count a board can
  overtake another while you are looking at it.

  The list is `Forum.list_public_forums/0` at mount and again on every refresh,
  which is the same predicate `list_readable_forums/1` composes: a board marked
  unlisted answers to its own slug and never arrives here, whoever is looking
  and however busy it gets. The badge is the board's stored counter rather than
  a count of its topics, so a page that lists every board does not load every
  board's collection to measure it.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Forum
  alias OpenAgentsWeb.LiveRefresh

  def mount(_params, _session, socket) do
    if connected?(socket), do: Forum.subscribe_posts()

    {:ok,
     socket
     |> LiveRefresh.init()
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> refresh_panel(:boards)}
  end

  def handle_info({:forum_posts_changed, _topic_id}, socket),
    do: {:noreply, LiveRefresh.mark_stale(socket, :boards, &refresh_panel/2)}

  def handle_info(:live_refresh, socket),
    do: {:noreply, LiveRefresh.run(socket, &refresh_panel/2)}

  defp refresh_panel(socket, :boards),
    do: assign(socket, :forums, Forum.list_public_forums())

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <div class="mx-auto w-full max-w-3xl">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-semibold tracking-tight">Forum</h1>
        </div>

        <%= if @forums == [] do %>
          <div class="alert" data-variant="info" role="status">
            <.icon name="info-circle" class="size-5" />
            <section>No boards yet.</section>
          </div>
        <% else %>
          <div class="flex flex-col gap-4">
            <%= for forum <- @forums do %>
              <.link
                navigate={~p"/forum/f/#{forum.slug}"}
                class="card !m-0 block hover:border-foreground/20 transition-colors"
              >
                <div class="flex items-baseline justify-between gap-3">
                  <h2 class="text-base font-semibold">{forum.title}</h2>
                  <span
                    id={"board-topics-#{forum.slug}"}
                    class="text-sm text-muted-foreground whitespace-nowrap"
                  >
                    {forum.topic_count} topics
                  </span>
                </div>
                <%= if forum.description do %>
                  <p class="text-sm text-muted-foreground mt-1.5 max-w-[60ch]">
                    {forum.description}
                  </p>
                <% end %>
              </.link>
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
