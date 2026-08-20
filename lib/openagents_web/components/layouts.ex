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

  attr :flush, :boolean,
    default: false,
    doc: "surface owns the full main area: no padding, no scroll of its own"

  slot :inner_block, required: true

  slot :title_menu,
    doc: """
    Actions belonging to this page, rendered beside its name in the command
    bar. Nested, never passed as an attribute: forwarding a slot as an attr
    compiles and renders but loses change tracking.
    """

  slot :sidebar_extra,
    doc: """
    Rows this page contributes to the application sidebar.

    A page with its own destinations adds them to the one sidebar rather than
    rendering a second one inside the content area. Chat did the latter, which
    put a whole nested application shell -- brand, rail, account footer --
    inside the padded main of the shell that already had one.
    """

  def app(assigns) do
    ~H"""
    <div class="h-screen flex overflow-hidden bg-background">
      <.sidebar :if={@current_scope} current_scope={@current_scope}>
        <:extra>{render_slot(@sidebar_extra)}</:extra>
      </.sidebar>

      <div class="flex-1 min-w-0 flex flex-col h-screen">
        <.openagents_command_bar current_scope={@current_scope} title={@title} subtitle={@subtitle}>
          <:menu>{render_slot(@title_menu)}</:menu>
        </.openagents_command_bar>

        <main class={[
          "flex-1 min-w-0",
          @flush && "flex min-h-0 flex-col overflow-hidden",
          !@flush && "overflow-y-auto overscroll-none p-4",
          @current_scope && "bg-background"
        ]}>
          <%!-- A flush surface owns the whole area and sets its own measure,
          so it is not wrapped either way. Signed out, an ordinary page is
          centred in a reading column; signed in, the page has the sidebar
          beside it and sets its own. --%>
          <%= if @flush or @current_scope do %>
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
  slot :menu, doc: "actions belonging to the current page"

  defp openagents_command_bar(assigns) do
    ~H"""
    <header class="flex items-center gap-2 bg-background border-b border-border px-4 h-[52px] shrink-0">
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
          {render_slot(@menu)}
        <% end %>
      </div>

      <div class="flex items-center gap-2">
        <.theme_toggle />
        <%= if @current_scope do %>
          <.account_dropdown current_scope={@current_scope} />
        <% else %>
          <%!-- A real sign-in, not a link to the homepage's anchor: a control
          labelled "log in" that navigates somewhere else instead is lying
          about what it does. --%>
          <UI.github_login id="command-bar-signin" size={:sm} />
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
  The brand lockup at the top of a documentation sidebar.

  Two targets, because they answer two different questions. The mark returns to
  the application, for a reader who arrived from a search result and wants the
  product. The title returns to this section's own index, for a reader who is
  already in the docs and wants the contents.

  Collapsing them into one link would cost one of those, and giving the index
  its own sidebar row would list a destination the reader is already looking at.
  """
  attr :title, :string, default: nil, doc: "section name; omitted in the app shell"
  attr :path, :string, default: nil, doc: "this section's index"

  def sidebar_brand(assigns) do
    ~H"""
    <header class="sidebar-brand">
      <.link navigate={~p"/"} class="sidebar-brand__mark" aria-label="OpenAgents home">
        <img src={~p"/favicon-32x32.png"} alt="" width="24" height="24" />
      </.link>
      <span :if={@title} class="sidebar-brand__divider" aria-hidden="true"></span>
      <.link :if={@title} patch={@path} class="sidebar-brand__title">{@title}</.link>
    </header>
    """
  end

  @doc """
  The secondary links at the foot of a sidebar.

  Every sidebar carries the same set, so a reader who finds the component
  library from the application can get back to the docs from either, and does
  not have to remember which shell they are in.

  The component library is advertised outside production only. It documents
  the parts a page is built from rather than anything a visitor came for.
  """
  attr :current_user, :map, default: nil, doc: "used only to decide whether admin shows"

  def sidebar_footer(assigns) do
    assigns =
      assigns
      |> assign(:components_link?, OpenAgents.RuntimeConfig.internal_surfaces_visible?())
      |> assign(:admin_link?, admin?(assigns[:current_user]))

    ~H"""
    <footer class="sidebar-footer">
      <.link
        :if={@admin_link?}
        id="open-admin"
        navigate={~p"/admin"}
        class="sidebar-footer__link"
        aria-label="Admin"
      >
        <UI.icon name="shield-lock" /> Admin
      </.link>
      <.link :if={@components_link?} navigate={~p"/components"} class="sidebar-footer__link">
        <UI.icon name="widget" /> Components
      </.link>
      <.link navigate={~p"/docs"} class="sidebar-footer__link">
        <UI.icon name="book" /> Documentation
      </.link>
      <.link navigate={~p"/leaderboard"} class="sidebar-footer__link">
        <UI.icon name="trophy-top" /> Leaderboard
      </.link>
    </footer>
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
  attr :id, :string, default: nil, doc: "defaults to a slug of the title"
  slot :inner_block, required: true

  def sidebar_section(assigns) do
    # Not `assign_new`: the `id` attr declaration already puts the key in
    # assigns as nil, so `assign_new` would consider it present and never
    # compute. A hook without a DOM id silently does not run.
    assigns =
      assign(assigns, :id, assigns.id || "sidebar-section-" <> section_slug(assigns.title))

    ~H"""
    <details
      id={@id}
      class="docs-sidebar__section sidebar-section"
      open={@open}
      phx-hook=".SidebarSection"
      data-holds-active={to_string(@open)}
    >
      <summary class="sidebar-section-label sidebar-section__summary">
        <UI.icon name="chevron-right" class="sidebar-section__caret" />
        <span>{@title}</span>
      </summary>
      <div class="sidebar-section__items">
        {render_slot(@inner_block)}
      </div>
    </details>
    <%!-- `open` above is a seed, not the truth. The server can only derive it
    from the active page, so re-deriving it on every navigation collapses every
    section the reader opened but is not currently inside. The hook makes the
    reader's own choices the state and keeps them in sessionStorage; the server
    still decides on first paint and whenever a section holds the active page,
    so a page can never be hidden inside a section the reader had closed, and
    the sidebar works with no JavaScript at all. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarSection">
      const KEY = "sidebar-sections"

      const read = () => {
        try {
          return JSON.parse(sessionStorage.getItem(KEY)) || {}
        } catch (_error) {
          return {}
        }
      }

      const write = (state) => {
        try {
          sessionStorage.setItem(KEY, JSON.stringify(state))
        } catch (_error) {
          // A full or unavailable store costs the reader their open sections
          // on the next navigation, which is the behaviour without the hook.
        }
      }

      export default {
        mounted() {
          this.onToggle = () => {
            const state = read()
            state[this.el.id] = this.el.open
            write(state)
          }
          // The caret rotates only for a turn the reader made. Navigation
          // re-renders `open`, so an always-on transition played an animation
          // on every move between pages. The attribute lives for one click.
          this.onClick = () => {
            this.el.dataset.animate = "true"
            clearTimeout(this.animateTimer)
            this.animateTimer = setTimeout(() => delete this.el.dataset.animate, 200)
          }
          this.summary = this.el.querySelector("summary")
          this.el.addEventListener("toggle", this.onToggle)
          if (this.summary) this.summary.addEventListener("click", this.onClick)
          this.restore()
        },
        updated() {
          this.restore()
        },
        destroyed() {
          clearTimeout(this.animateTimer)
          this.el.removeEventListener("toggle", this.onToggle)
          if (this.summary) this.summary.removeEventListener("click", this.onClick)
        },
        restore() {
          // A section holding the active page opens regardless of what the
          // reader last did, so navigation can never land on a hidden row.
          if (this.el.dataset.holdsActive === "true") {
            this.el.open = true
            this.onToggle()
            return
          }
          const stored = read()[this.el.id]
          if (stored !== undefined) this.el.open = stored
        },
      }
    </script>
    """
  end

  # Ids have to survive navigation for the reader's open sections to be found
  # again, so they come from the section name rather than a render-time counter.
  defp section_slug(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
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
      <div class="menu__identity">
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
      <.link navigate={~p"/settings/api-tokens"} role="menuitem" class="menu__item">
        <UI.icon name="key" /> API tokens
      </.link>
      <.form for={%{}} id="logout-form" action={~p"/logout"} method="delete" class="menu__form">
        <button id="logout" type="submit" role="menuitem" class="menu__item">
          <UI.icon name="logout" /> Log out
        </button>
      </.form>
    </UI.menu>
    """
  end

  # The command bar's identity control. Renders the same panel and the same
  # rows as `account_control/1`. There were two account menus with two
  # different sets of markup -- one on Tailwind utilities against
  # `bg-popover`, one on the design system -- so the menu the chat surface
  # showed and the menu the command bar showed did not look like the same
  # application. There is one now.
  attr :current_scope, :map, required: true

  defp account_dropdown(assigns) do
    ~H"""
    <UI.button
      id="account-bar-trigger"
      variant={:ghost}
      size={:sm}
      class="account-menu-trigger"
      popovertarget="account-bar-menu"
      popovertargetaction="toggle"
      aria-label={"Account menu for @#{@current_scope.github_login}"}
    >
      <UI.avatar
        src={@current_scope.github_avatar_url}
        alt={"GitHub avatar for @#{@current_scope.github_login}"}
        size={:sm}
      />
    </UI.button>

    <UI.menu id="account-bar-menu" class="account-menu">
      <div class="menu__identity">
        <UI.avatar
          src={@current_scope.github_avatar_url}
          alt={"GitHub avatar for @#{@current_scope.github_login}"}
          size={:lg}
        />
        <span>
          <strong>{account_display_name(@current_scope)}</strong>
          <small :if={@current_scope.github_name}>@{@current_scope.github_login}</small>
        </span>
      </div>
      <.link navigate={~p"/settings/api-tokens"} role="menuitem" class="menu__item">
        <UI.icon name="key" /> API tokens
      </.link>
      <.form for={%{}} as={:logout} action={~p"/logout"} method="delete" class="menu__form">
        <button type="submit" role="menuitem" class="menu__item">
          <UI.icon name="logout" /> Log out
        </button>
      </.form>
    </UI.menu>
    """
  end

  attr :current_scope, :map, required: true

  slot :extra, doc: "rows contributed by the current page"

  defp sidebar(assigns) do
    ~H"""
    <aside id="sidebar" class="sidebar hidden lg:flex">
      <Layouts.sidebar_brand />

      <nav class="sidebar-nav" aria-label="OpenAgents surfaces">
        <Layouts.sidebar_link path={~p"/"} label="Home" icon="home" patchable={false} />
        <Layouts.sidebar_link path={~p"/chat"} label="Chat" icon="chat" patchable={false} />
        <Layouts.sidebar_link
          path={~p"/OpenAgentsInc/openagents.com/issues"}
          label="Issues"
          icon="bug"
          patchable={false}
        />
        <Layouts.sidebar_link
          path={~p"/OpenAgentsInc/openagents.com/projects"}
          label="Projects"
          icon="folder"
          patchable={false}
        />
        <Layouts.sidebar_link
          path={~p"/computers"}
          label="Computers"
          icon="desktop"
          patchable={false}
        />
        <Layouts.sidebar_link
          path={~p"/memory"}
          label="Memory"
          icon="brain"
          patchable={false}
        />
      </nav>

      <%!-- Rows the current page contributes. Chat's destinations, work
      projections and admin actions arrive here instead of in a second rail. --%>
      {render_slot(@extra)}

      <Layouts.sidebar_footer current_user={@current_scope} />
    </aside>
    """
  end

  # A nil scope is not an operator. The footer renders on public pages too.
  defp admin?(nil), do: false
  defp admin?(user), do: OpenAgents.Accounts.admin?(user)

  @doc """
  The browser title: the page's own name, then the brand.

  Returns nil when the page has no name, so `live_title`'s default renders the
  brand alone instead of appending it to itself.
  """
  def page_title(assigns) do
    case assigns[:page_title] do
      title when is_binary(title) and title != "" -> title <> " · OpenAgents"
      _absent -> nil
    end
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
