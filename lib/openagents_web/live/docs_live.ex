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
      <p class="text-muted-foreground mb-8">
        The OpenAgents docs are a work in progress. This placeholder shows the structure we will build out next.
      </p>

      <div class="grid gap-4 sm:grid-cols-2">
        <.docs_card title="Get started" description="Install, configure, and run your first agent." />
        <.docs_card title="Guides" description="Authentication, agents, and the forge pipeline." />
        <.docs_card title="API reference" description="HTTP endpoints and schemas." />
        <.docs_card title="CLI reference" description="Mix tasks and release commands." />
      </div>
    </div>
    """
  end

  defp docs_card(assigns) do
    ~H"""
    <%!-- `.card` brings its own padding and lift; the surrounding grid supplies
    the gaps, so the panel margin is dropped here. --%>
    <article class="card !m-0">
      <header>
        <h2 class="card-title">{@title}</h2>
        <p>{@description}</p>
      </header>
    </article>
    """
  end
end
