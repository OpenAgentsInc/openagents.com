defmodule OpenAgentsWeb.ComponentsLive do
  @moduledoc """
  Public catalog of reusable HEEx components that ship in this codebase.

  `/components` is an index; each component gets its own page at
  `/components/:slug`. The sidebar and the set of valid slugs both come from
  `OpenAgentsWeb.ComponentCatalog`, so navigation and pages cannot drift.

  Planned forge and issues components are listed in `docs/component-library.md`.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgentsWeb.ComponentCatalog

  @sample_rows [
    %{id: 1, owner: "OpenAgentsInc", repo: "openagents.com", state: "open"},
    %{id: 2, owner: "OpenAgentsInc", repo: "sarah", state: "open"},
    %{id: 3, owner: "OpenAgentsInc", repo: "arcade", state: "closed"}
  ]

  @icons ~w(
    hero-information-circle hero-exclamation-circle hero-x-mark
    hero-arrow-path hero-sun-micro hero-moon-micro hero-computer-desktop-micro
  )

  @impl true
  def mount(_params, _session, socket) do
    form =
      to_form(
        %{
          "title" => "Ship the component catalog",
          "body" => "Show every reusable control on one page.",
          "state" => "open",
          "public" => "true"
        },
        as: :demo
      )

    {:ok,
     socket
     |> assign(:form, form)
     |> assign(:rows, @sample_rows)
     |> assign(:icons, @icons)}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Components")
     |> assign(:active_component, :index)
     |> assign(:item, nil)}
  end

  def handle_params(%{"slug" => slug}, _uri, socket) do
    case ComponentCatalog.fetch(slug) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Unknown component: #{slug}")
         |> push_navigate(to: ~p"/components")}

      item ->
        {:noreply,
         socket
         |> assign(:page_title, item.title)
         |> assign(:active_component, item.slug)
         |> assign(:item, item)}
    end
  end

  @impl true
  def handle_event("validate", %{"demo" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :demo))}
  end

  def handle_event("save", _params, socket) do
    {:noreply, put_flash(socket, :info, "Demo form submitted. Nothing was saved.")}
  end

  def handle_event("flash-info", _params, socket) do
    {:noreply, put_flash(socket, :info, "This is the info flash from CoreComponents.")}
  end

  def handle_event("flash-error", _params, socket) do
    {:noreply, put_flash(socket, :error, "This is the error flash from CoreComponents.")}
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <div id="components-index" class="max-w-3xl">
      <h1 class="text-3xl font-semibold mb-4">Component library</h1>
      <p class="text-base-content/70 mb-8 text-pretty max-w-[68ch]">
        Live examples of every reusable function component in this repository.
        These controls come from <code>OpenAgentsWeb.CoreComponents</code>
        and <code>OpenAgentsWeb.Layouts</code>, styled with DaisyUI. Planned
        GitHub-shaped components are listed in <code>docs/component-library.md</code>.
      </p>

      <section :for={section <- ComponentCatalog.sections()} class="mb-10">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50 mb-3">
          {section.title}
        </h2>
        <div class="grid gap-4 sm:grid-cols-2">
          <.link
            :for={item <- section.items}
            navigate={~p"/components/#{item.slug}"}
            class="card bg-base-200 border border-base-300 p-4 hover:border-base-content/30"
          >
            <h3 class="text-lg font-medium mb-1">{item.title}</h3>
            <p class="text-sm text-base-content/70">{item.summary}</p>
          </.link>
        </div>
      </section>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id={"component-#{@item.slug}"} class="max-w-3xl space-y-6">
      <header class="space-y-1">
        <h1 class="text-3xl font-semibold">{@item.title}</h1>
        <p class="text-sm text-base-content/70"><code>{@item.source}</code></p>
        <p class="text-base text-base-content/70 text-pretty max-w-[68ch]">{@item.summary}</p>
      </header>

      <div class="rounded-box border border-base-300 bg-base-100 p-6">
        <.component_demo {assigns} />
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :form, :any, default: nil
  attr :rows, :list, default: []
  attr :icons, :list, default: []

  defp component_demo(%{item: %{slug: "button"}} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <.button id="demo-button-default">Default</.button>
      <.button id="demo-button-primary" variant="primary">Primary</.button>
      <.button id="demo-button-navigate" navigate={~p"/"}>Navigate home</.button>
      <.button id="demo-button-disabled" disabled>Disabled</.button>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "input"}} = assigns) do
    ~H"""
    <.form
      for={@form}
      id="component-form"
      phx-change="validate"
      phx-submit="save"
      class="grid gap-4 sm:grid-cols-2"
    >
      <div>
        <.input field={@form[:title]} label="Title" />
      </div>
      <div>
        <.input
          field={@form[:state]}
          type="select"
          label="State"
          options={[{"Open", "open"}, {"Closed", "closed"}]}
        />
      </div>
      <div class="sm:col-span-2">
        <.input field={@form[:body]} type="textarea" label="Body" />
      </div>
      <div>
        <.input field={@form[:public]} type="checkbox" label="Public repository" />
      </div>
      <div class="flex items-end">
        <.button type="submit" variant="primary">Save demo</.button>
      </div>
    </.form>
    """
  end

  defp component_demo(%{item: %{slug: "header"}} = assigns) do
    ~H"""
    <.header>
      Repository issues
      <:subtitle>Open and closed issues for this repository.</:subtitle>
      <:actions>
        <.button variant="primary">New issue</.button>
      </:actions>
    </.header>
    """
  end

  defp component_demo(%{item: %{slug: "table"}} = assigns) do
    ~H"""
    <.table id="demo-table" rows={@rows}>
      <:col :let={row} label="Owner">{row.owner}</:col>
      <:col :let={row} label="Repository">{row.repo}</:col>
      <:col :let={row} label="State">{row.state}</:col>
      <:action :let={row}>
        <.link navigate={~p"/"} class="link link-hover">View {row.repo}</.link>
      </:action>
    </.table>
    """
  end

  defp component_demo(%{item: %{slug: "list"}} = assigns) do
    ~H"""
    <.list>
      <:item title="Flash">Toast alerts for info and error.</:item>
      <:item title="Button">Primary and soft variants, plus navigation.</:item>
      <:item title="Input">Text, select, textarea, and checkbox.</:item>
    </.list>
    """
  end

  defp component_demo(%{item: %{slug: "icon"}} = assigns) do
    ~H"""
    <ul id="demo-icons" role="list" class="flex flex-wrap gap-4">
      <li :for={name <- @icons} class="flex flex-col items-center gap-2 w-28">
        <.icon name={name} class="size-6" />
        <p class="text-center text-sm text-base-content/70">{name}</p>
      </li>
    </ul>
    """
  end

  defp component_demo(%{item: %{slug: "flash"}} = assigns) do
    ~H"""
    <p class="text-pretty text-base text-base-content/70 max-w-[68ch] mb-4">
      Flash renders through <code>Layouts.flash_group/1</code>
      at the corner of the page. Trigger a sample message:
    </p>
    <div class="flex flex-wrap gap-3">
      <.button id="demo-flash-info" phx-click="flash-info">Show info flash</.button>
      <.button id="demo-flash-error" phx-click="flash-error">Show error flash</.button>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "theme-toggle"}} = assigns) do
    ~H"""
    <div id="demo-theme-toggle">
      <Layouts.theme_toggle />
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "repo-header"}} = assigns) do
    ~H"""
    <OpenAgentsWeb.Components.RepoHeader.repo_header
      owner="OpenAgentsInc"
      repo="openagents.com"
      active="issues"
      open_count={12}
      closed_count={148}
    />
    """
  end
end
