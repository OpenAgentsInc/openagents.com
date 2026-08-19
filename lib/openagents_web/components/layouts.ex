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
    <div class="h-screen flex flex-col overflow-hidden bg-base-100">
      <.command_bar current_scope={@current_scope} />

      <div class="flex-1 flex min-h-0">
        <%= if @current_scope do %>
          <.sidebar current_scope={@current_scope} />
        <% end %>

        <main class={[
          "flex-1 min-w-0 h-full overflow-y-auto overscroll-none p-4",
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
        <.link navigate={~p"/"} class="btn btn-ghost text-xl">
          OpenAgents
        </.link>
      </div>

      <div class="navbar-end gap-2">
        <%= if @current_scope do %>
          <.account_dropdown current_scope={@current_scope} />
        <% else %>
          <.form for={%{}} as={:auth} action={~p"/auth/github"} method="post" class="m-0">
            <.button type="submit" class="btn btn-primary btn-sm">Sign in with GitHub</.button>
          </.form>
        <% end %>
        <.theme_toggle />
      </div>
    </header>
    """
  end

  defp account_dropdown(assigns) do
    ~H"""
    <details class="dropdown dropdown-end">
      <summary class="btn btn-ghost btn-sm list-none flex items-center gap-2 cursor-pointer">
        <img
          src={@current_scope.github_avatar_url}
          alt={"GitHub avatar for @#{@current_scope.github_login}"}
          class="w-8 h-8 rounded-full"
        />
        <span class="hidden sm:inline">@{@current_scope.github_login}</span>
        <.icon name="hero-chevron-down" class="size-4" />
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
    <aside class="w-64 hidden lg:flex flex-col border-r border-base-300 bg-base-200 h-full">
      <nav class="flex-1 p-4 overflow-y-auto">
        <ul class="menu menu-sm rounded-box space-y-1">
          <li>
            <.link navigate={~p"/"}>
              <.icon name="hero-home" class="size-4" /> Home
            </.link>
          </li>
          <li>
            <.link navigate={~p"/chat"}>
              <.icon name="hero-chat-bubble-left-right" class="size-4" /> Chat
            </.link>
          </li>
          <li>
            <.link navigate={~p"/components"}>
              <.icon name="hero-squares-2x2" class="size-4" /> Components
            </.link>
          </li>
          <li>
            <.link navigate={~p"/OpenAgents/openagents/issues"}>
              <.icon name="hero-circle-stack" class="size-4" /> Issues
            </.link>
          </li>
          <li>
            <.link navigate={~p"/OpenAgents/openagents/projects"}>
              <.icon name="hero-rectangle-group" class="size-4" /> Projects
            </.link>
          </li>
        </ul>

        <div class="mt-6">
          <h3 class="text-xs font-bold uppercase text-base-content/50 mb-2 px-3">Work</h3>
          <ul class="menu menu-sm rounded-box space-y-1">
            <li><a>Explore repo</a></li>
            <li><a>Plan change</a></li>
            <li><a>Run tests</a></li>
          </ul>
        </div>

        <div class="mt-6">
          <h3 class="text-xs font-bold uppercase text-base-content/50 mb-2 px-3">Memory</h3>
          <p class="text-sm text-base-content/70 px-3">No saved records yet.</p>
        </div>
      </nav>

      <div class="p-4 border-t border-base-300">
        <div class="flex items-center gap-3">
          <img
            src={@current_scope.github_avatar_url}
            alt={"GitHub avatar for @#{@current_scope.github_login}"}
            class="w-10 h-10 rounded-full"
          />
          <div class="min-w-0">
            <p class="font-semibold truncate">{account_display_name(@current_scope)}</p>
            <p :if={@current_scope.github_name} class="text-sm text-base-content/70 truncate">
              @{@current_scope.github_login}
            </p>
          </div>
        </div>
      </div>
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
