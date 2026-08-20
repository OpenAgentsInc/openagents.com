defmodule OpenAgentsWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use OpenAgentsWeb, :html

  alias OpenAgentsWeb.UI, as: UI

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

  attr :title, :string, default: nil, doc: "the page title to display in the command bar"

  attr :subtitle, :string, default: nil, doc: "the page subtitle to display in the command bar"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="h-screen flex overflow-hidden bg-background">
      <%= if @current_scope do %>
        <.sidebar current_scope={@current_scope} />
      <% end %>

      <div class="flex-1 min-w-0 flex flex-col h-screen">
        <.openagents_command_bar current_scope={@current_scope} title={@title} subtitle={@subtitle} />

        <main class={[
          "flex-1 min-w-0 overflow-y-auto overscroll-none p-4",
          @current_scope && "bg-background"
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

  attr :current_scope, :map, default: nil
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil

  defp openagents_command_bar(assigns) do
    ~H"""
    <header class="flex items-center gap-2 bg-background border-b border-border px-4 h-16 shrink-0">
      <div class="flex flex-1 min-w-0 items-center gap-2">
        <%= if !@current_scope do %>
          <.link navigate={~p"/"} class="btn text-xl text-foreground" data-variant="ghost">
            OpenAgents
          </.link>
        <% end %>
        <%= if @title do %>
          <div class="flex flex-col justify-center min-w-0">
            <h1 class="text-base font-semibold leading-tight truncate">{@title}</h1>
            <%= if @subtitle do %>
              <p class="text-xs text-muted-foreground truncate">{@subtitle}</p>
            <% end %>
          </div>
        <% end %>
      </div>

      <div class="flex items-center gap-2">
        <.theme_toggle />
        <%= if @current_scope do %>
          <.account_dropdown current_scope={@current_scope} />
        <% else %>
          <.button navigate={~p"/#github-tools"} variant={:primary} size={:sm}>
            Sign in with GitHub
          </.button>
        <% end %>
      </div>
    </header>
    """
  end

  @doc """
  The OpenAgents command bar: brand lockup on the left, account controls on the
  right. `current_user` is optional because public surfaces are anonymous.
  """
  attr :aria_label, :string, required: true
  attr :current_user, :map, default: nil
  slot :lockup, doc: "chip controls rendered beside the brand name"
  slot :controls, doc: "surface-specific controls rendered before the account menu"

  def command_bar(assigns) do
    ~H"""
    <header class="command-bar" aria-label={@aria_label}>
      <div class="brand-lockup">
        <span class="brand-name">OpenAgents</span>
        {render_slot(@lockup)}
      </div>
      <div class="command-controls">
        {render_slot(@controls)}

        <.theme_toggle />
        <.account_control :if={@current_user} current_user={@current_user} />
      </div>
    </header>
    """
  end

  @doc """
  A collapsible sidebar section.

  A native `<details>`, so it needs no JavaScript, is keyboard operable, and
  reports its own state to assistive technology. Because the sidebar now
  patches rather than remounts, the element survives navigation and so does
  whatever the reader collapsed.

  `open` should be true for the section holding the current page: collapsing
  the section you are reading would hide your own location.
  """
  attr :title, :string, required: true
  attr :open, :boolean, default: false
  slot :inner_block, required: true

  def sidebar_section(assigns) do
    ~H"""
    <details class="docs-sidebar__section sidebar-section" open={@open}>
      <summary class="sidebar-section-label sidebar-section__summary">
        <UI.icon name="chevron-right" class="sidebar-section__caret" />
        <span>{@title}</span>
      </summary>
      <div class="sidebar-section__items">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  @doc """
  A sidebar row that navigates without throwing the sidebar away.

  `/components` and `/components/:slug` are the same LiveView, so moving
  between them is a patch: the DOM is diffed, the row's selected state updates
  in place, and the sidebar keeps its scroll position. `navigate` would remount
  and scroll the list back to the top on every click.

  `/components/icons` is a different LiveView, so a patch cannot reach it and a
  patch cannot leave it. `patchable` says whether the currently mounted view is
  the one that owns these params; when it is not, the row falls back to a
  navigate that remounts on purpose.
  """
  attr :path, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :selected, :boolean, default: false
  attr :patchable, :boolean, default: false

  def sidebar_link(assigns) do
    ~H"""
    <div class="sidebar-row" data-selected={@selected}>
      <.link
        :if={@patchable}
        patch={@path}
        class="sidebar-row__hit"
        aria-label={@label}
        aria-current={@selected && "page"}
      ></.link>
      <.link
        :if={!@patchable}
        navigate={@path}
        class="sidebar-row__hit"
        aria-label={@label}
        aria-current={@selected && "page"}
      ></.link>
      <span class="sidebar-row__content">
        <span class="sidebar-row__icon"><UI.icon name={@icon} /></span>
        <span class="sidebar-row__label">{@label}</span>
      </span>
    </div>
    """
  end

  @doc """
  One control that flips between light and dark.

  There is no explicit "system" rung. Storing nothing IS system, and that is the
  default until someone chooses: the head script leaves `data-theme` unset and
  the `prefers-color-scheme` fallback in `app.css` governs. A third button would
  make the common case — never touching this at all — look like an unmade
  decision.

  The glyph shows the theme you would move to, not the one you are in, because
  the control is an action rather than a status. Which glyph is visible cannot
  be decided here: the effective theme depends on the visitor's OS when nothing
  is stored, so the head script resolves it and the CSS picks the glyph.
  """
  def theme_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class="btn theme-toggle"
      data-variant="ghost"
      data-size="sm"
      aria-label="Toggle theme"
      title="Toggle theme"
      phx-click={JS.dispatch("phx:toggle-theme")}
    >
      <UI.icon name="sun" class="theme-toggle__sun" />
      <UI.icon name="moon" class="theme-toggle__moon" />
    </button>
    """
  end

  @doc """
  The one authenticated identity control: an avatar trigger opening a bounded
  native popover with the same identity and a labeled `LOG OUT` action.
  """
  attr :current_user, :map, required: true
  attr :context, :atom, values: [:bar, :row], default: :bar

  def account_control(assigns) do
    ~H"""
    <UI.button
      id="account-menu-trigger"
      variant={if(@context == :row, do: :ghost, else: :secondary)}
      size={:sm}
      class={["account-menu-trigger", @context == :row && "account-menu-trigger--row"]}
      popovertarget="account-menu"
      popovertargetaction="toggle"
      aria-label={"Account menu for @#{@current_user.github_login}"}
    >
      <UI.avatar src={@current_user.github_avatar_url} size={:sm} />
      <span :if={@context == :bar}>@{@current_user.github_login}</span>
      <span :if={@context == :row} class="account-trigger-identity">
        <strong>{account_display_name(@current_user)}</strong>
        <small :if={@current_user.github_name} class="!text-[0.75rem]">@{@current_user.github_login}</small>
      </span>
      <UI.icon name="chevron-down" class="account-menu-trigger__caret" />
    </UI.button>

    <UI.menu id="account-menu" class="account-menu">
      <div class="account-menu__identity">
        <UI.avatar
          src={@current_user.github_avatar_url}
          alt={"GitHub avatar for @#{@current_user.github_login}"}
          size={:lg}
        />
        <span>
          <strong>{account_display_name(@current_user)}</strong>
          <small :if={@current_user.github_name}>@{@current_user.github_login}</small>
        </span>
      </div>
      <.form for={%{}} id="logout-form" action={~p"/logout"} method="delete">
        <UI.button
          id="logout"
          variant={:ghost}
          type="submit"
          role="menuitem"
          class="account-menu__logout"
        >
          <UI.icon name="logout" /> Log out
        </UI.button>
      </.form>
      <.link navigate={~p"/settings/api-tokens"} role="menuitem" class="account-menu__logout">
        API tokens
      </.link>
      <.form
        :if={github_tools_connected?(@current_user)}
        for={%{}}
        id="github-disconnect-form"
        action={~p"/github/connection"}
        method="delete"
      >
        <UI.button
          id="github-disconnect"
          variant={:ghost}
          type="submit"
          role="menuitem"
          class="account-menu__logout"
        >
          Disconnect GitHub tools
        </UI.button>
      </.form>
    </UI.menu>
    """
  end

  defp account_dropdown(assigns) do
    ~H"""
    <%!-- A native <details> disclosure rather than a JavaScript dropdown, for
    the same reason `UI.menu/1` uses the popover API: the account control
    has to work before any client script has run. --%>
    <details class="relative">
      <summary class="btn list-none cursor-pointer !p-1" data-variant="ghost">
        <img
          src={@current_scope.github_avatar_url}
          alt={"GitHub avatar for @#{@current_scope.github_login}"}
          class="w-8 h-8 rounded-full"
        />
      </summary>
      <ul class="absolute end-0 z-10 mt-2 w-56 rounded-lg border border-border bg-popover p-2 shadow-lg">
        <li class="flex flex-col p-2">
          <span class="font-semibold">{account_display_name(@current_scope)}</span>
          <span :if={@current_scope.github_name} class="text-sm text-muted-foreground">
            @{@current_scope.github_login}
          </span>
        </li>
        <li>
          <.link
            navigate={~p"/settings/api-tokens"}
            class="btn w-full justify-start"
            data-variant="ghost"
          >
            API tokens
          </.link>
        </li>
        <li>
          <.form
            :if={github_tools_connected?(@current_scope)}
            for={%{}}
            action={~p"/github/connection"}
            method="delete"
            class="m-0 w-full"
          >
            <.button type="submit" variant={:ghost} class="w-full justify-start">
              Disconnect GitHub tools
            </.button>
          </.form>
        </li>
        <li>
          <.form for={%{}} as={:logout} action={~p"/logout"} method="post" class="m-0 w-full">
            <input type="hidden" name="_method" value="delete" />
            <button
              type="submit"
              class="w-full rounded-md px-2 py-1.5 text-left flex items-center gap-2 hover:bg-muted"
            >
              <.icon name="logout" class="size-4" /> Log out
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
            navigate={~p"/OpenAgentsInc/openagents.com/issues"}
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
            navigate={~p"/OpenAgentsInc/openagents.com/projects"}
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
        <.icon name="arrow-rotate-cw" class="ml-1 size-3 motion-safe:animate-spin" />
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
        <.icon name="arrow-rotate-cw" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :flash, :map, default: %{}
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], required: true
  attr :rest, :global
  slot :inner_block

  defp flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={message = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed top-4 right-4 z-50 flex flex-col items-end gap-2"
      {@rest}
    >
      <UI.alert
        class="w-80 max-w-80 text-wrap sm:w-96 sm:max-w-96"
        variant={if(@kind == :error, do: :danger, else: :info)}
        label={@title}
      >
        {message}
        <:action>
          <UI.button
            type="button"
            variant={:ghost}
            size={:xs}
            aria-label={gettext("Dismiss notice")}
          >
            <UI.icon name="x" />
          </UI.button>
        </:action>
      </UI.alert>
    </div>
    """
  end

  defp show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all transform ease-out duration-300", "opacity-0 translate-y-4",
         "opacity-100 translate-y-0"}
    )
  end

  defp github_tools_connected?(user) when is_map(user),
    do: is_binary(Map.get(user, :github_token_ciphertext))

  defp github_tools_connected?(_user), do: false

  defp hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200", "opacity-100 translate-y-0",
         "opacity-0 translate-y-4"}
    )
  end
end
