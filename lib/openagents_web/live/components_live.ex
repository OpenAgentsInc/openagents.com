defmodule OpenAgentsWeb.ComponentsLive do
  @moduledoc """
  Public catalog of reusable HEEx components that ship in this codebase.

  Renders every function component in `OpenAgentsWeb.CoreComponents` and
  `OpenAgentsWeb.Layouts` (except `Layouts.app/1` and `flash_group/1`, which
  wrap this page). Planned forge and issues components live in
  `docs/component-library.md`.
  """

  use OpenAgentsWeb, :live_view

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
     |> assign(:page_title, "Components")
     |> assign(:form, form)
     |> assign(:rows, @sample_rows)
     |> assign(:icons, @icons)}
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
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} wide>
      <div id="components-gallery" class="space-y-12">
        <header class="space-y-3">
          <.header>
            Component library
            <:subtitle>
              Live examples of every reusable function component in this
              repository. Planned GitHub-shaped components are listed in
              docs/component-library.md.
            </:subtitle>
          </.header>
          <p class="text-pretty text-base text-base-content/70 max-w-[68ch]">
            These controls come from <code>OpenAgentsWeb.CoreComponents</code>
            and <code>OpenAgentsWeb.Layouts</code>. DaisyUI classes style them.
            New forge and issues components should land in a dedicated module
            and appear on this page when they ship.
          </p>
        </header>

        <.catalog_section
          id="section-button"
          title="Button"
          source="OpenAgentsWeb.CoreComponents.button/1"
        >
          <div class="flex flex-wrap items-center gap-3">
            <.button id="demo-button-default">Default</.button>
            <.button id="demo-button-primary" variant="primary">Primary</.button>
            <.button id="demo-button-navigate" navigate={~p"/"}>Navigate home</.button>
            <.button id="demo-button-disabled" disabled>Disabled</.button>
          </div>
        </.catalog_section>

        <.catalog_section
          id="section-input"
          title="Input"
          source="OpenAgentsWeb.CoreComponents.input/1"
        >
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
        </.catalog_section>

        <.catalog_section
          id="section-header"
          title="Header"
          source="OpenAgentsWeb.CoreComponents.header/1"
        >
          <.header>
            Repository issues
            <:subtitle>Open and closed issues for this repository.</:subtitle>
            <:actions>
              <.button variant="primary">New issue</.button>
            </:actions>
          </.header>
        </.catalog_section>

        <.catalog_section
          id="section-table"
          title="Table"
          source="OpenAgentsWeb.CoreComponents.table/1"
        >
          <.table id="demo-table" rows={@rows}>
            <:col :let={row} label="Owner">{row.owner}</:col>
            <:col :let={row} label="Repository">{row.repo}</:col>
            <:col :let={row} label="State">{row.state}</:col>
            <:action :let={row}>
              <.link navigate={~p"/"} class="link link-hover">View {row.repo}</.link>
            </:action>
          </.table>
        </.catalog_section>

        <.catalog_section
          id="section-list"
          title="List"
          source="OpenAgentsWeb.CoreComponents.list/1"
        >
          <.list>
            <:item title="Flash">Toast alerts for info and error.</:item>
            <:item title="Button">Primary and soft variants, plus navigation.</:item>
            <:item title="Input">Text, select, textarea, and checkbox.</:item>
          </.list>
        </.catalog_section>

        <.catalog_section
          id="section-icon"
          title="Icon"
          source="OpenAgentsWeb.CoreComponents.icon/1"
        >
          <ul id="demo-icons" role="list" class="flex flex-wrap gap-4">
            <li :for={name <- @icons} class="flex flex-col items-center gap-2 w-28">
              <.icon name={name} class="size-6" />
              <p class="text-center text-sm text-base-content/70">{name}</p>
            </li>
          </ul>
        </.catalog_section>

        <.catalog_section
          id="section-flash"
          title="Flash"
          source="OpenAgentsWeb.CoreComponents.flash/1"
        >
          <p class="text-pretty text-base text-base-content/70 max-w-[68ch]">
            Flash renders through <code>Layouts.flash_group/1</code> at the
            corner of the page. Trigger a sample message:
          </p>
          <div class="flex flex-wrap gap-3">
            <.button id="demo-flash-info" phx-click="flash-info">Show info flash</.button>
            <.button id="demo-flash-error" phx-click="flash-error">Show error flash</.button>
          </div>
        </.catalog_section>

        <.catalog_section
          id="section-theme-toggle"
          title="Theme toggle"
          source="OpenAgentsWeb.Layouts.theme_toggle/1"
        >
          <p class="text-pretty text-base text-base-content/70 max-w-[68ch]">
            System, light, and dark. The same control is in the site header.
          </p>
          <div id="demo-theme-toggle">
            <Layouts.theme_toggle />
          </div>
        </.catalog_section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :source, :string, required: true
  slot :inner_block, required: true

  defp catalog_section(assigns) do
    ~H"""
    <section id={@id} class="space-y-4">
      <div class="space-y-1">
        <h2 class="text-xl font-semibold tracking-tight text-balance">{@title}</h2>
        <p class="text-sm text-base-content/70"><code>{@source}</code></p>
      </div>
      <div class="rounded-box border border-base-300 bg-base-100 p-6">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
