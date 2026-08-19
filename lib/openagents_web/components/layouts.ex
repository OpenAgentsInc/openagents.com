defmodule OpenAgentsWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use OpenAgentsWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :wide, :boolean,
    default: false,
    doc: "use a wider content column for catalog and list surfaces"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="h-screen flex overflow-hidden bg-base-100">
      <%= if @current_scope do %>
        <.sidebar current_scope={@current_scope} />
      <% end %>

      <div class="flex-1 min-w-0 flex flex-col h-screen">
        <.command_bar current_scope={@current_scope} />

        <main class={[
          "flex-1 min-w-0 overflow-y-auto overscroll-none p-4",
          @current_scope && "bg-base-100"
        ]}>
          <%= if @current_scope do %>
            {render_slot(@inner_block)}
          <% else %>
            <div class={["mx-auto space-y-4", @wide && "max-w-6xl", !@wide && "max-w-2xl"]}>
              {render_slot(@inner_block)}
            </div>
          <% end %>
        </main>
      </div>

      <.flash_group flash={@flash} class="fixed bottom-4 right-4 z-50" />
    </div>
    """
  end

  defp command_bar(assigns) do
    ~H"""
    <header class="navbar bg-base-100 border-b border-base-300 px-4 h-16 shrink-0">
      <div class="navbar-start">
        <%= if !@current_scope do %>
          <.link navigate={~p"/"} class="btn btn-ghost text-xl">
            OpenAgents
          </.link>
        <% end %>
      </div>

      <div class="navbar-end gap-2">
        <%= if @current_scope do %>
          <.account_dropdown current_scope={@current_scope} />
        <% else %>
          <.form for={%{}} as={:auth} action={~p"/auth/github"} method="post" class="m-0">
            <.button type="submit" class="btn btn-primary btn-sm">Sign in with GitHub</.button>
          </.form>
        <% end %>
      </div>
    </header>
    """
  end

  defp account_dropdown(assigns) do
    ~H"""
    <details class="dropdown dropdown-end">
      <summary class="btn btn-ghost btn-circle avatar list-none cursor-pointer">
        <img
          src={@current_scope.github_avatar_url}
          alt={"GitHub avatar for @#{@current_scope.github_login}"}
          class="w-8 h-8 rounded-full"
        />
      </summary>
      <ul class="menu dropdown-content bg-base-100 rounded-box z-10 w-56 p-2 shadow border border-base-300">
        <li class="p-2">
          <span class="font-semibold">{account_display_name(@current_scope)}</span>
          <span :if={@current_scope.github_name} class="text-sm text-base-content/70">
            @{@current_scope.github_login}
          </span>
        </li>
        <li>
          <.form for={%{}} as={:logout} action={~p"/logout"} method="post" class="m-0 w-full">
            <input type="hidden" name="_method" value="delete" />
            <button type="submit" class="w-full text-left flex items-center gap-2">
              <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Log out
            </button>
          </.form>
        </li>
      </ul>
    </details>
    """
  end

  defp sidebar(assigns) do
    ~H"""
    <aside class="sidebar hidden lg:flex">
      <header class="sidebar-header">
        <span class="brand-name">OpenAgents</span>
      </header>

      <nav class="sidebar-nav" aria-label="OpenAgents surfaces">
        <div class="sidebar-row">
          <.link navigate={~p"/"} class="sidebar-row__hit" aria-label="Home"></.link>
          <span class="sidebar-row__content">
            <span class="sidebar-row__icon"><.icon name="home" /></span>
            <span class="sidebar-row__label">Home</span>
          </span>
        </div>

        <div class="sidebar-row">
          <.link navigate={~p"/chat"} class="sidebar-row__hit" aria-label="Chat"></.link>
          <span class="sidebar-row__content">
            <span class="sidebar-row__icon"><.icon name="chat" /></span>
            <span class="sidebar-row__label">Chat</span>
          </span>
        </div>

        <div class="sidebar-row">
          <.link
            navigate={~p"/OpenAgents/openagents/issues"}
            class="sidebar-row__hit"
            aria-label="Issues"
          ></.link>
          <span class="sidebar-row__content">
            <span class="sidebar-row__icon"><.icon name="bug" /></span>
            <span class="sidebar-row__label">Issues</span>
          </span>
        </div>

        <div class="sidebar-row">
          <.link
            navigate={~p"/OpenAgents/openagents/projects"}
            class="sidebar-row__hit"
            aria-label="Projects"
          ></.link>
          <span class="sidebar-row__content">
            <span class="sidebar-row__icon"><.icon name="folder" /></span>
            <span class="sidebar-row__label">Projects</span>
          </span>
        </div>
      </nav>

      <%!--
      <div class="sidebar-sections">
        <section class="sidebar-section" aria-label="Work">
          <h2 class="sidebar-section-label">WORK</h2>
          <div class="sidebar-row sidebar-row--static">
            <span class="sidebar-row__content">
              <span class="sidebar-row__icon"><.icon name="bolt" /></span>
              <span class="sidebar-row__label">Explore repo</span>
            </span>
          </div>
          <div class="sidebar-row sidebar-row--static">
            <span class="sidebar-row__content">
              <span class="sidebar-row__icon"><.icon name="bolt" /></span>
              <span class="sidebar-row__label">Plan change</span>
            </span>
          </div>
          <div class="sidebar-row sidebar-row--static">
            <span class="sidebar-row__content">
              <span class="sidebar-row__icon"><.icon name="bolt" /></span>
              <span class="sidebar-row__label">Run tests</span>
            </span>
          </div>
        </section>
      </div>
      --%>

      <nav class="sidebar-nav" aria-label="OpenAgents tools">
        <div class="sidebar-row">
          <.link navigate={~p"/components"} class="sidebar-row__hit" aria-label="Components"></.link>
          <span class="sidebar-row__content">
            <span class="sidebar-row__icon"><.icon name="widget" /></span>
            <span class="sidebar-row__label">Components</span>
          </span>
        </div>
        <div class="sidebar-row">
          <.link navigate={~p"/docs"} class="sidebar-row__hit" aria-label="Documentation"></.link>
          <span class="sidebar-row__content">
            <span class="sidebar-row__icon"><.icon name="book" /></span>
            <span class="sidebar-row__label">Documentation</span>
          </span>
        </div>
      </nav>
    </aside>
    """
  end

  defp account_display_name(%{github_name: name}) when is_binary(name) and name != "", do: name
  defp account_display_name(%{github_login: login}), do: "@" <> login

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"
  attr :class, :any, default: nil, doc: "additional classes for the container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class={@class} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
