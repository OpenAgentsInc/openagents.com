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

      <Layouts.app flash={@flash} sidebar_sections={assigns[:sidebar_sections]}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :sidebar_sections, :any,
    default: %{},
    doc: """
    Which sidebar sections the reader has collapsed, from their cookie. Passed
    down rather than read ambiently so a page that renders a sidebar cannot
    quietly lose it -- `test/openagents_web/sidebar_state_test.exs` fails on a
    call site that omits it.
    """

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
    <div
      id="app-shell"
      class="h-screen flex overflow-hidden bg-background"
      phx-hook=".AppSidebar"
    >
      <.sidebar
        :if={@current_scope}
        current_scope={@current_scope}
        sidebar_sections={@sidebar_sections || %{}}
      >
        <:extra>{render_slot(@sidebar_extra)}</:extra>
      </.sidebar>

      <button
        :if={@current_scope}
        id="sidebar-scrim"
        type="button"
        class="sidebar-scrim"
        aria-label="Close navigation sidebar"
        aria-hidden="true"
        tabindex="-1"
      ></button>

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

      <script :type={Phoenix.LiveView.ColocatedHook} name=".AppSidebar">
        export default {
          mounted() {
            this.desktop = window.matchMedia("(min-width: 1024px)")
            this.onClick = event => this.handleClick(event)
            this.onKeydown = event => this.handleKeydown(event)
            this.onBreakpointChange = () => this.restoreForViewport()

            this.el.addEventListener("click", this.onClick)
            window.addEventListener("keydown", this.onKeydown)
            this.desktop.addEventListener("change", this.onBreakpointChange)
            this.restoreForViewport()
          },

          updated() {
            this.applyState(this.open)
          },

          destroyed() {
            this.el.removeEventListener("click", this.onClick)
            window.removeEventListener("keydown", this.onKeydown)
            this.desktop.removeEventListener("change", this.onBreakpointChange)
            document.body.classList.remove("sidebar-open")
          },

          handleClick(event) {
            if (event.target.closest("#sidebar-toggle")) {
              this.applyState(!this.open, {focusSidebar: !this.open})
              return
            }

            if (event.target.closest("#sidebar-scrim")) {
              this.applyState(false, {restoreFocus: true})
              return
            }

            if (!this.desktop.matches && event.target.closest("#sidebar a")) {
              this.applyState(false)
            }
          },

          handleKeydown(event) {
            if (event.key === "Escape" && this.open && !this.desktop.matches) {
              this.applyState(false, {restoreFocus: true})
            }
          },

          restoreForViewport() {
            const open = this.desktop.matches
            this.applyState(open)
          },

          applyState(open, options = {}) {
            const sidebar = this.el.querySelector("#sidebar")
            const toggle = this.el.querySelector("#sidebar-toggle")
            const scrim = this.el.querySelector("#sidebar-scrim")
            if (!sidebar || !toggle || !scrim) return

            this.open = open
            this.el.dataset.sidebarInitialized = "true"
            this.el.dataset.sidebarOpen = open ? "true" : "false"
            sidebar.setAttribute("aria-hidden", open ? "false" : "true")
            sidebar.inert = !open
            toggle.setAttribute("aria-expanded", open ? "true" : "false")
            toggle.setAttribute(
              "aria-label",
              open ? "Collapse navigation sidebar" : "Open navigation sidebar"
            )
            toggle.title = open ? "Collapse navigation sidebar" : "Open navigation sidebar"
            scrim.setAttribute("aria-hidden", open ? "false" : "true")
            document.body.classList.toggle("sidebar-open", open && !this.desktop.matches)

            if (options.focusSidebar && !this.desktop.matches) {
              window.requestAnimationFrame(() => {
                sidebar.querySelector("a, button, summary")?.focus()
              })
            } else if (options.restoreFocus) {
              toggle.focus()
            }
          }
        }
      </script>
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
        <UI.button
          :if={@current_scope}
          id="sidebar-toggle"
          class="sidebar-toggle"
          variant={:ghost}
          size={:sm}
          aria-label="Open navigation sidebar"
          aria-controls="sidebar"
          aria-expanded="false"
          title="Open navigation sidebar"
        >
          <UI.icon name="menu" class="sidebar-toggle__open" />
          <UI.icon name="sidebar-collapse-left" class="sidebar-toggle__collapse" />
        </UI.button>
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
      <%!-- The application's own rail carries the wordmark; the docs and
      component shells do not, because the section name beside the divider is
      already doing that half of the job and "OpenAgents | Docs" said the brand
      twice. Mark and word are one link, so the whole lockup goes home. --%>
      <.link navigate={~p"/"} class="sidebar-brand__mark" aria-label="OpenAgents home">
        <img src={~p"/favicon-32x32.png"} alt="" width="24" height="24" />
        <span :if={is_nil(@title)} class="sidebar-brand__wordmark">OpenAgents</span>
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
  # Required, with no default. Defaulting to nil made a forgotten attribute
  # look exactly like a signed-out visitor, and the docs and component-library
  # layouts both forgot it -- so an operator browsing either surface silently
  # lost the Admin row. `nil` is still a fine thing to pass; it just has to be
  # said.
  attr :current_user, :any,
    required: true,
    doc: "the scope whose access decides the admin row; nil for a visitor"

  def sidebar_footer(assigns) do
    assigns =
      assigns
      |> assign(:components_link?, OpenAgents.RuntimeConfig.internal_surfaces_visible?())
      |> assign(:admin_link?, admin?(assigns[:current_user]))

    ~H"""
    <footer class="sidebar-footer">
      <.link navigate={~p"/docs"} class="sidebar-footer__link">
        <UI.icon name="book" /> Documentation
      </.link>
      <.link :if={@components_link?} navigate={~p"/components"} class="sidebar-footer__link">
        <UI.icon name="widget" /> Components
      </.link>
      <.link navigate={~p"/leaderboard"} class="sidebar-footer__link">
        <UI.icon name="trophy-top" /> Leaderboard
      </.link>
      <.link
        :if={@admin_link?}
        id="open-admin"
        navigate={~p"/admin"}
        class="sidebar-footer__link"
        aria-label="Admin"
      >
        <UI.icon name="shield-lock" /> Admin
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

  attr :open, :boolean,
    default: false,
    doc: "the seed, used until the reader has said otherwise for this section"

  attr :state, :map,
    default: %{},
    doc: """
    The reader's collapsed/expanded sections, keyed by element id, as carried
    from their cookie by `OpenAgentsWeb.Plugs.SidebarSections`. Applied here,
    on the server, so a full page load paints what they chose rather than
    painting the seed and having a hook correct it a frame later.
    """

  attr :id, :string, default: nil, doc: "defaults to a slug of the title"
  slot :inner_block, required: true

  def sidebar_section(assigns) do
    # Not `assign_new`: the `id` attr declaration already puts the key in
    # assigns as nil, so `assign_new` would consider it present and never
    # compute. A hook without a DOM id silently does not run.
    assigns =
      assigns
      |> assign(:id, assigns.id || "sidebar-section-" <> section_slug(assigns.title))
      |> then(fn assigns ->
        assign(assigns, :open, Map.get(assigns.state, assigns.id, assigns.open))
      end)

    ~H"""
    <details
      id={@id}
      class="docs-sidebar__section sidebar-section"
      open={@open}
      phx-hook=".SidebarSection"
    >
      <summary class="sidebar-section-label sidebar-section__summary">
        <UI.icon name="chevron-right" class="sidebar-section__caret" />
        <span>{@title}</span>
      </summary>
      <div class="sidebar-section__items">
        {render_slot(@inner_block)}
      </div>
    </details>
    <%!-- `open` above is a seed, not the truth. Re-applying it on every
    navigation collapses every section the reader opened but is not currently
    inside, and re-opens every section they closed that happens to be open by
    default. The hook makes the reader's own choices the state and keeps them
    in sessionStorage; the seed decides first paint, and a section containing
    the active row still opens regardless, so a page can never be hidden inside
    a section the reader had closed. With no JavaScript the seed governs and
    the sidebar still works. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarSection">
      // A cookie rather than sessionStorage, because the server has to know.
      // Several sidebar destinations live in different live sessions, so
      // moving between them is a full page load; state the server cannot read
      // arrives too late, and the reader watches a section they collapsed
      // paint open and then shut. See `OpenAgentsWeb.Plugs.SidebarSections`.
      const KEY = "sidebar_sections"

      const read = () => {
        const entry = document.cookie
          .split("; ")
          .find((part) => part.startsWith(KEY + "="))
        if (!entry) return {}
        try {
          return JSON.parse(decodeURIComponent(entry.slice(KEY.length + 1))) || {}
        } catch (_error) {
          return {}
        }
      }

      const write = (state) => {
        const value = encodeURIComponent(JSON.stringify(state))
        // Session-scoped, same-site, and readable by script because script is
        // what maintains it. It holds which sidebar sections are open, so it
        // is not worth protecting and must not be sent cross-site.
        document.cookie = KEY + "=" + value + "; path=/; samesite=lax"
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
          // Asked of the DOM rather than of the server: the active row already
          // marks itself `aria-current`, and a server-side answer has to be
          // derived from the section's `open` attribute, which is true for a
          // section that is merely open by default -- so every navigation
          // re-forced such a section open and undid the reader's collapse.
          if (this.el.querySelector("[aria-current]")) {
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
  attr :sidebar_sections, :map, required: true

  slot :extra, doc: "rows contributed by the current page"

  defp sidebar(assigns) do
    assigns =
      assigns
      |> assign(:agent_surfaces?, agent_surfaces?(assigns[:current_scope]))
      |> assign(:repository_path, assigns.current_scope.sidebar_repository_path)

    ~H"""
    <aside id="sidebar" class="sidebar" aria-hidden="true">
      <Layouts.sidebar_brand />

      <nav class="sidebar-nav" aria-label="OpenAgents surfaces">
        <Layouts.sidebar_link path={~p"/"} label="Home" icon="home" patchable={false} />
        <Layouts.sidebar_link
          path={~p"/repositories"}
          label="Repositories"
          icon="branch"
          patchable={false}
        />
        <Layouts.sidebar_link
          :if={@repository_path}
          path={@repository_path <> "/issues"}
          label="Issues"
          icon="bug"
          patchable={false}
        />
        <Layouts.sidebar_link
          :if={@repository_path}
          path={@repository_path <> "/projects"}
          label="Projects"
          icon="folder"
          patchable={false}
        />
      </nav>

      <%!-- The agent's own surfaces, grouped under her name. Chat, computers
      and memory are one thing from the reader's side -- the conversation and
      the two things it can reach -- and reading as a group says that in a way
      six flat rows cannot. Open by default: grouping is for orientation here,
      not for hiding. --%>
      <Layouts.sidebar_section
        :if={@agent_surfaces?}
        title="Sarah"
        open
        state={@sidebar_sections}
      >
        <Layouts.sidebar_link path={~p"/chat"} label="Chat" icon="chat" patchable={false} />
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
      </Layouts.sidebar_section>

      <%!-- Rows the current page contributes. Chat's destinations, work
      projections and admin actions arrive here instead of in a second rail. --%>
      {render_slot(@extra)}

      <Layouts.sidebar_footer current_user={@current_scope} />
    </aside>
    """
  end

  # The agent's surfaces are grandfathered, not launched: an account that has
  # already talked to her keeps them, and an operator always has them, but a
  # new account never sees them. `agent_surfaces?` is resolved once by
  # `UserAuth.on_mount/4`; this runs on every render, so it must stay a field
  # read and never become a query.
  defp agent_surfaces?(nil), do: false
  defp agent_surfaces?(user), do: user.agent_surfaces? or admin?(user)

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

  @doc """
  The `og:*` / `twitter:*` block for the root layout.

  Views that build an `OpenAgentsWeb.OG` card assign `:og` (via `OG.meta/2`)
  and this renders it; every other page gets honest site-level tags rather
  than nothing. Crawlers read the initial server-rendered HTML, so these tags
  ride the first paint only — exactly where they are consumed.
  """
  attr :og, :map, default: nil, doc: "an `OpenAgentsWeb.OG.meta/2` map"

  def og_tags(assigns) do
    og =
      assigns[:og] ||
        %{
          title: "OpenAgents",
          description: "Code hosting, issues, and projects on the agent-native forge.",
          type: "website",
          url: OpenAgentsWeb.OG.site_url(),
          image_url: OpenAgentsWeb.OG.static_card_url(),
          alt: "OpenAgents — code hosting, issues, and projects."
        }

    assigns = assign(assigns, :og, og)

    ~H"""
    <meta property="og:site_name" content="OpenAgents" />
    <meta property="og:type" content={@og.type} />
    <meta property="og:title" content={@og.title} />
    <meta property="og:description" content={@og.description} />
    <meta property="og:url" content={@og.url} />
    <meta property="og:image" content={@og.image_url} />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta property="og:image:alt" content={@og.alt} />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content={@og.title} />
    <meta name="twitter:description" content={@og.description} />
    <meta name="twitter:image" content={@og.image_url} />
    """
  end

  @doc """
  One browser analytics identity field from the session-written map, or nil.

  The root layout renders these as data attributes for `app.js`; a missing or
  malformed identity renders nothing rather than raising.
  """
  def posthog_identity(assigns, key) when is_atom(key) do
    case assigns[:posthog_identity] do
      %{} = identity ->
        case identity[Atom.to_string(key)] do
          value when is_binary(value) and value != "" -> value
          _other -> nil
        end

      _absent ->
        nil
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
