defmodule OpenAgentsWeb.DocsLive do
  @moduledoc """
  A placeholder docs landing page.
  """

  use OpenAgentsWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Docs")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto">
      <h1 class="text-3xl font-semibold mb-4">Documentation</h1>
      <p class="text-base-content/70 mb-8">
        The OpenAgents docs are a work in progress. This placeholder shows the structure we will build out next.
      </p>

      <div class="grid gap-4 sm:grid-cols-2">
        <.card title="Get started" description="Install, configure, and run your first agent." />
        <.card title="Guides" description="Authentication, agents, and the forge pipeline." />
        <.card title="API reference" description="HTTP endpoints and schemas." />
        <.card title="CLI reference" description="Mix tasks and release commands." />
      </div>
    </div>
    """
  end

  defp card(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300 p-4">
      <h2 class="text-lg font-medium mb-1">{@title}</h2>
      <p class="text-sm text-base-content/70">{@description}</p>
    </div>
    """
  end
end
