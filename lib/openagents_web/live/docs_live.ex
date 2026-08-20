defmodule OpenAgentsWeb.DocsLive do
  @moduledoc """
  Renders the Markdown pages catalogued in `OpenAgentsWeb.DocsCatalog`.

  `/docs` is the index and `/docs/:slug` is a page; both are this LiveView, so
  moving between them patches rather than remounts, and the sidebar keeps its
  scroll position and whatever the reader collapsed.

  Markdown goes through `OpenAgents.Markdown`, the same safe CommonMark path
  the chat surface uses. Documentation is authored content, but it renders with
  the same guarantees as content from a model: no raw HTML passthrough.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgentsWeb.DocsCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :sections, DocsCatalog.sections())}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Docs")
     |> assign(:active_page, :index)
     |> assign(:section_title, nil)
     |> assign(:page, nil)}
  end

  def handle_params(%{"slug" => slug}, _uri, socket) do
    case DocsCatalog.render(slug) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(:page_title, page.item.title)
         |> assign(:active_page, page.item.slug)
         |> assign(:section_title, DocsCatalog.section_title(page.item.slug))
         |> assign(:page, page)}

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, "No such page: #{slug}")
         |> push_navigate(to: ~p"/docs")}
    end
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <div id="docs-index" class="docs-prose">
      <h1>Documentation</h1>
      <p>
        Everything documented here is something you can reach today. Where a page
        describes a surface, that surface exists and is clickable.
      </p>

      <section :for={section <- @sections}>
        <h2 id={DocsCatalog.anchor(section.title)}>{section.title}</h2>
        <ul>
          <li :for={item <- section.items}>
            <.link patch={~p"/docs/#{item.slug}"}>{item.title}</.link>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="docs-page">
      <article class="docs-prose" id={"docs-#{@page.item.slug}"}>
        {Phoenix.HTML.raw(@page.html)}
      </article>

      <%!-- The rail is the page's own structure, so it comes from the same
      parse that produced the body rather than being maintained beside it.
      Hidden when a page has too few headings to be worth navigating. --%>
      <nav :if={length(@page.toc) > 1} class="docs-toc" aria-label="On this page">
        <p class="docs-toc__title">On this page</p>
        <ul>
          <li :for={heading <- @page.toc} data-level={heading.level}>
            <a href={"##{heading.id}"}>{heading.title}</a>
          </li>
        </ul>
      </nav>
    </div>
    """
  end
end
