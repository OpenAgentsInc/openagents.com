defmodule OpenAgentsWeb.IconIndexLive do
  @moduledoc """
  Catalog page that shows every icon in the vendored OpenAI Apps SDK UI set.
  """

  use OpenAgentsWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Icons")
     |> assign(:active_component, :icons)
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:icons, OpenAgentsWeb.Icons.names())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-3xl font-semibold mb-4">Icons ({length(@icons)} glyphs)</h1>

      <div class="grid grid-cols-2 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8 gap-4">
        <%= for name <- @icons do %>
          <div class="flex flex-col items-center gap-2 p-3 border border-base-300 rounded-lg">
            <.icon name={name} class="size-8" />
            <span class="text-xs text-center break-all text-base-content/70">{name}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
