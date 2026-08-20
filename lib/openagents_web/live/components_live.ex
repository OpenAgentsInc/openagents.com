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
  alias OpenAgentsWeb.UI.Circle
  alias OpenAgentsWeb.UI.Graph
  alias OpenAgentsWeb.UI.Landing
  alias OpenAgentsWeb.UI, as: UI

  @sample_rows [
    %{id: 1, owner: "OpenAgentsInc", repo: "openagents.com", state: "open"},
    %{id: 2, owner: "OpenAgentsInc", repo: "openagents.com", state: "open"},
    %{id: 3, owner: "OpenAgentsInc", repo: "arcade", state: "closed"}
  ]

  # Six issues spanning every status category, every priority, assigned and
  # unassigned. A demo that shows one happy row hides exactly the cases the
  # component was built to keep legible.
  @demo_issues [
    %{
      identifier: "OA-142",
      title: "Placement refuses a node whose capability manifest has expired",
      status_category: :started,
      status_label: "In progress",
      progress: 35,
      priority: :urgent,
      labels: [%{name: "Bug", tone: :danger}, %{name: "Cloud", tone: :info}],
      project: "Managed nodes",
      due: "Aug 22",
      created: "Aug 12",
      assignee: %{name: "Mason Carter", presence: :online}
    },
    %{
      identifier: "OA-138",
      title: "Bound every atom attribute so a bad call site fails at compile time",
      status_category: :completed,
      status_label: "Done",
      priority: :high,
      labels: [%{name: "Refactor", tone: :warning}],
      created: "Aug 9",
      assignee: %{name: "Priya Raman", presence: :away}
    },
    %{
      identifier: "OA-151",
      title: "Diff parser drops the enclosing-function hint on a truncated hunk",
      status_category: :triage,
      status_label: "Triage",
      priority: :medium,
      labels: [%{name: "Forge", tone: :success}],
      created: "Aug 18",
      assignee: nil
    },
    %{
      identifier: "OA-119",
      title: "Command palette should say which issue it is acting on",
      status_category: :unstarted,
      status_label: "Todo",
      priority: :low,
      labels: [%{name: "UI", tone: :primary}],
      project: "Component library",
      created: "Jul 30",
      assignee: %{name: "Tomas Lindqvist", presence: :offline}
    },
    %{
      identifier: "OA-102",
      title: "Investigate whether receipts can be signed on the node itself",
      status_category: :backlog,
      status_label: "Backlog",
      priority: :none,
      labels: [],
      created: "Jul 14",
      assignee: nil
    },
    %{
      identifier: "OA-097",
      title: "Second theme selector, superseded by the token ladder",
      status_category: :canceled,
      status_label: "Cancelled",
      priority: :none,
      labels: [%{name: "Design", tone: :neutral}],
      created: "Jul 2",
      assignee: %{name: "Ada Okafor", presence: :none}
    }
  ]

  @demo_people [
    %{name: "Mason Carter"},
    %{name: "Priya Raman"},
    %{name: "Tomas Lindqvist"},
    %{name: "Ada Okafor"},
    %{name: "Jun Watanabe"},
    %{name: "Fiona Bell"},
    %{name: "Ravi Menon"},
    %{name: "Lena Fischer"}
  ]

  # The catalog demonstrates the preferred vendored Apps SDK tier. Heroicons
  # remains an exceptional fallback with an empty product-use inventory.
  @openagents_icons ~w(sparkle compass folder document user bell play star)

  # account_control/1 and command_bar/1 read three fields off the current user.
  # A plain map is enough and keeps the catalog page free of database access.
  @demo_user %{
    github_login: "openagents-demo",
    github_name: "Demo Account",
    github_avatar_url: nil
  }

  # Fifteen SCVs spanning every status, so the swarm page is the taxonomy in
  # aggregate rather than a happy-path screenshot.
  @demo_swarm [
    %{id: "scv-01", status: :running, label: "01", weight: 0.9, item_status: :running},
    %{id: "scv-02", status: :running, label: "02", weight: 0.3, item_status: :running},
    %{id: "scv-03", status: :idle, label: "03", weight: 0.0},
    %{id: "scv-04", status: :running, label: "04", weight: 0.6, item_status: :admitted},
    %{id: "scv-05", status: :paused, label: "05", weight: 0.4, item_status: :deferred},
    %{id: "scv-06", status: :idle, label: "06", weight: 0.0},
    %{id: "scv-07", status: :circuit_open, label: "07", weight: 0.2},
    %{id: "scv-08", status: :running, label: "08", weight: 1.0, item_status: :running},
    %{id: "scv-09", status: :disabled, label: "09", weight: 0.0},
    %{id: "scv-10", status: :running, label: "10", weight: 0.5, item_status: :completed},
    %{id: "scv-11", status: :idle, label: "11", weight: 0.0},
    %{id: "scv-12", status: :paused, label: "12", weight: 0.7, item_status: :refused},
    %{id: "scv-13", status: :running, label: "13", weight: 0.15, item_status: :failed},
    %{id: "scv-14", status: :disabled, label: "14", weight: 0.0},
    %{id: "scv-15", status: :running, label: "15", weight: 0.8, item_status: :discovered}
  ]

  # The same fifteen agents as the swarm, with the tail each is emitting. Text
  # is representative of real OpenCode output rather than lorem, so the row
  # width is exercised the way it will be in use.
  @demo_streams [
    %{
      id: "scv-01",
      label: "scv-01",
      status: :running,
      weight: 0.9,
      tool: "edit",
      text: "applying patch to lib/openagents/forge/hot_loader.ex (3 hunks)"
    },
    %{
      id: "scv-02",
      label: "scv-02",
      status: :running,
      weight: 0.3,
      tool: "bash",
      text: "mix test test/openagents/forge/targets_test.exs --seed 0"
    },
    %{
      id: "scv-03",
      label: "scv-03",
      status: :idle,
      weight: 0.0,
      text: "waiting for admitted work"
    },
    %{
      id: "scv-04",
      label: "scv-04",
      status: :running,
      weight: 0.6,
      tool: "read",
      text: "reading docs/scv-planning.md to bound the objective"
    },
    %{
      id: "scv-05",
      label: "scv-05",
      status: :paused,
      weight: 0.4,
      tool: "edit",
      text: "paused: budget window exhausted, resumes at the next window"
    },
    %{
      id: "scv-06",
      label: "scv-06",
      status: :idle,
      weight: 0.0,
      text: "waiting for admitted work"
    },
    %{
      id: "scv-07",
      label: "scv-07",
      status: :circuit_open,
      weight: 0.2,
      text: "circuit open after 3 consecutive provider timeouts"
    },
    %{
      id: "scv-08",
      label: "scv-08",
      status: :running,
      weight: 1.0,
      tool: "grep",
      text: "searching for remaining callers of Sarah.Forge.Targets.promote/4"
    },
    %{
      id: "scv-09",
      label: "scv-09",
      status: :disabled,
      weight: 0.0,
      text: "disabled by operator"
    },
    %{
      id: "scv-10",
      label: "scv-10",
      status: :running,
      weight: 0.5,
      tool: "bash",
      text: "mix precommit -- 1416 passed, 14 excluded"
    },
    %{
      id: "scv-11",
      label: "scv-11",
      status: :idle,
      weight: 0.0,
      text: "waiting for admitted work"
    },
    %{
      id: "scv-12",
      label: "scv-12",
      status: :paused,
      weight: 0.7,
      tool: "read",
      text: "paused: awaiting human promotion under SELF-EDIT-001"
    },
    %{
      id: "scv-13",
      label: "scv-13",
      status: :running,
      weight: 0.15,
      tool: "edit",
      text: "reverting: regression test still red after the third attempt"
    },
    %{
      id: "scv-14",
      label: "scv-14",
      status: :disabled,
      weight: 0.0,
      text: "disabled by operator"
    },
    %{
      id: "scv-15",
      label: "scv-15",
      status: :running,
      weight: 0.8,
      tool: "write",
      text: "writing test/openagents_web/components/graph_test.exs"
    }
  ]

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
     |> assign(:openagents_icons, @openagents_icons)
     |> assign(:demo_user, @demo_user)
     |> assign(:demo_swarm, @demo_swarm)
     |> assign(:demo_streams, @demo_streams)
     |> assign(:demo_issues, @demo_issues)
     |> assign(:demo_people, @demo_people)}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Components")
     |> assign(:active_component, :index)
     |> assign(:section_title, nil)
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
         |> assign(:section_title, section_title_for(item.slug))
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

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <div id="components-index" class="max-w-3xl">
      <h1 class="text-3xl font-semibold mb-4">Component library</h1>
      <p class="text-muted-foreground mb-8 text-pretty max-w-[68ch]">
        Live examples of every supported function component in <code>OpenAgentsWeb.UI</code>, <code>OpenAgentsWeb.Layouts</code>, and the
        repository header. A test asserts this page covers every public component
        in those modules.
        Planned GitHub-shaped components are listed in <code>docs/component-library.md</code>.
      </p>

      <section :for={section <- ComponentCatalog.sections()} class="mb-10">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-muted-foreground mb-3">
          {section.title}
        </h2>
        <div class="grid gap-4 sm:grid-cols-2">
          <.link
            :for={item <- section.items}
            patch={~p"/components/#{item.slug}"}
            class="card bg-card border border-border p-4 hover:border-foreground/30"
          >
            <h3 class="text-lg font-medium mb-1">{item.title}</h3>
            <p class="text-sm text-muted-foreground">{item.summary}</p>
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
        <p class="text-sm text-muted-foreground"><code>{@item.source}</code></p>
        <p class="text-base text-muted-foreground text-pretty max-w-[68ch]">{@item.summary}</p>
      </header>

      <div class="rounded-lg border border-border bg-background p-6">
        <.component_demo {assigns} />
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :form, :any, default: nil
  attr :rows, :list, default: []
  attr :openagents_icons, :list, default: []
  attr :demo_user, :map, default: nil
  attr :demo_issues, :list, default: []
  attr :demo_people, :list, default: []

  defp component_demo(%{item: %{slug: "openagents-input"}} = assigns) do
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
        <.button type="submit" variant={:primary}>Save demo</.button>
      </div>
    </.form>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-header"}} = assigns) do
    ~H"""
    <.header>
      Repository issues
      <:subtitle>Open and closed issues for this repository.</:subtitle>
      <:actions>
        <.button variant={:primary}>New issue</.button>
      </:actions>
    </.header>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-table"}} = assigns) do
    ~H"""
    <.table id="demo-table" rows={@rows}>
      <:col :let={row} label="Owner">{row.owner}</:col>
      <:col :let={row} label="Repository">{row.repo}</:col>
      <:col :let={row} label="State">{row.state}</:col>
      <:action :let={row}>
        <.link navigate={~p"/"} class="underline underline-offset-2 hover:no-underline">
          View {row.repo}
        </.link>
      </:action>
    </.table>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-list"}} = assigns) do
    ~H"""
    <.list>
      <:item title="Flash">Toast alerts for info and error.</:item>
      <:item title="Button">Primary and soft variants, plus navigation.</:item>
      <:item title="Input">Text, select, textarea, and checkbox.</:item>
    </.list>
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

  # --- OpenAgents UI -------------------------------------------------------------

  defp component_demo(%{item: %{slug: "openagents-button"}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex flex-wrap items-center gap-3">
        <UI.button
          :for={v <- ~w(primary secondary outline ghost destructive chip notched link)a}
          id={"demo-button-#{v}"}
          variant={v}
        >
          {v |> Atom.to_string() |> String.capitalize()}
        </UI.button>
      </div>
      <div class="flex flex-wrap items-center gap-3">
        <UI.button :for={sz <- ~w(xs sm default lg)a} size={sz}>{sz}</UI.button>
      </div>
      <div class="flex flex-wrap items-center gap-3">
        <UI.button tone={:danger}>Danger tone</UI.button>
        <UI.button id="demo-button-disabled" disabled>Disabled</UI.button>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-text-button"}} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-4">
      <UI.text_button>Default</UI.text_button>
      <UI.text_button tone={:danger}>Danger</UI.text_button>
      <UI.text_button disabled>Disabled</UI.text_button>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-textarea"}} = assigns) do
    ~H"""
    <div class="max-w-sm">
      <UI.textarea
        id="openagents-textarea-demo"
        name="demo_body"
        value="Multi-line text primitive."
        rows="4"
      />
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-label"}} = assigns) do
    ~H"""
    <div class="space-y-2 max-w-sm">
      <UI.label for="openagents-label-target">Repository name</UI.label>
      <UI.input id="openagents-label-target" name="repo" value="openagents.com" />
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-field"}} = assigns) do
    ~H"""
    <div class="max-w-sm space-y-4">
      <UI.field>
        <UI.label for="openagents-field-title">Title</UI.label>
        <UI.input id="openagents-field-title" name="title" value="Ship the component catalog" />
      </UI.field>
      <UI.field>
        <UI.label for="openagents-field-body">Body</UI.label>
        <UI.textarea id="openagents-field-body" name="body" rows="3" />
      </UI.field>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-alert"}} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="space-y-3">
        <p class="text-sm text-muted-foreground">Variants (box appearance)</p>
        <UI.alert :for={v <- ~w(info success warning danger)a} variant={v} label={Atom.to_string(v)}>
          A {v} alert in the default box appearance.
        </UI.alert>
      </div>
      <div class="space-y-3">
        <p class="text-sm text-muted-foreground">Appearances</p>
        <UI.alert
          :for={a <- ~w(box row notice)a}
          appearance={a}
          variant={:info}
          label={Atom.to_string(a)}
        >
          The {a} appearance.
        </UI.alert>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-badge"}} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <UI.badge :for={v <- ~w(default info success warning danger dim)a} variant={v}>
        {v}
      </UI.badge>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-card"}} = assigns) do
    ~H"""
    <div class="grid gap-4 sm:grid-cols-2">
      <UI.card id="openagents-card-default">
        <p class="font-medium">Default</p>
        <p class="text-sm text-muted-foreground">A plain content container.</p>
      </UI.card>
      <UI.card id="openagents-card-corners" frame={:corners}>
        <p class="font-medium">Corner frame</p>
        <p class="text-sm text-muted-foreground">With bracket decoration.</p>
      </UI.card>
      <UI.card id="openagents-card-danger" variant={:danger}>
        <p class="font-medium">Danger</p>
        <p class="text-sm text-muted-foreground">For destructive context.</p>
      </UI.card>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-avatar"}} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-end gap-6">
      <UI.avatar :for={sz <- ~w(sm default lg)a} size={sz} fallback="OA" label={"size #{sz}"} />
      <UI.avatar tone={:accent} fallback="AC" label="accent tone" />
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-item"}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <UI.item status="ok" label="Fleet node 1" detail="converged" />
      <UI.item status="pending" label="Fleet node 2" detail="rolling" />
      <UI.item status="error" label="Fleet node 3" detail="unreachable" />
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-event-header"}} = assigns) do
    ~H"""
    <UI.event_header
      id="openagents-event-header-demo"
      status="ok"
      title="repo_commit_push"
      status_note="completed"
      timestamp={~U[2026-08-19 21:51:00Z]}
    >
      <:chips>
        <UI.badge variant={:dim}>tool</UI.badge>
      </:chips>
      <p class="text-sm text-muted-foreground">Pushed 3 files to the forge.</p>
    </UI.event_header>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-empty"}} = assigns) do
    ~H"""
    <UI.empty id="openagents-empty-demo" title="No delegations yet">
      Work you delegate to a paired machine will appear here.
    </UI.empty>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-kbd"}} = assigns) do
    ~H"""
    <p class="flex flex-wrap items-center gap-2 text-sm">
      Press
      <UI.kbd>⌘</UI.kbd>

      <UI.kbd>K</UI.kbd>
      to open the command bar, or
      <UI.kbd>Esc</UI.kbd>
      to dismiss it.
    </p>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-menu"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <UI.button popovertarget="openagents-demo-menu" popovertargetaction="toggle">
        Open menu
      </UI.button>
      <UI.menu id="openagents-demo-menu" label="Demo menu">
        <UI.text_button>Profile</UI.text_button>
        <UI.text_button>Settings</UI.text_button>
        <UI.text_button tone={:danger}>Sign out</UI.text_button>
      </UI.menu>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-frame"}} = assigns) do
    ~H"""
    <UI.frame>
      <div class="p-6">
        <p class="font-medium">Framed content</p>
        <p class="text-sm text-muted-foreground">Corner brackets wrap arbitrary children.</p>
      </div>
    </UI.frame>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-status-indicator"}} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-6">
      <UI.status_indicator state="ok" label="Healthy" />
      <UI.status_indicator state="pending" label="Converging" />
      <UI.status_indicator state="error" label="Degraded" />
      <UI.status_indicator state="ok" label="Decorative" decorative />
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-audio-player"}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <UI.audio_player
        id="openagents-audio-demo"
        src="/audio/does-not-exist.wav"
        label="Voice recording (demo source, nothing to play)"
      />
      <p class="text-sm text-muted-foreground">
        The src is intentionally a dead path; this page has no recording to serve.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-icon"}} = assigns) do
    ~H"""
    <ul id="openagents-demo-icons" role="list" class="flex flex-wrap gap-4">
      <li :for={name <- @openagents_icons} class="flex flex-col items-center gap-2 w-28">
        <UI.icon name={name} class="size-6" />
        <p class="text-center text-sm text-muted-foreground">{name}</p>
      </li>
    </ul>
    """
  end

  # --- Layout ---------------------------------------------------------------

  defp component_demo(%{item: %{slug: "sidebar-brand"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Two destinations, not one. The wordmark leaves for the application; the
        section name returns to this section's index. The rule between them says
        they are separate controls — without it, two links at the same weight read
        as a single label.
      </p>
      <div class="max-w-xs" style="border: 1px solid var(--line); border-radius: 8px;">
        <Layouts.sidebar_brand title="Components" path={~p"/components"} />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "sidebar-section"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A native <code>&lt;details&gt;</code>, so it needs no JavaScript and no ARIA
        kept in sync by hand. Click a heading to collapse it.
      </p>
      <div class="docs-sidebar__nav max-w-xs">
        <Layouts.sidebar_section title="Open by default" open>
          <Layouts.sidebar_link path="#" label="First" icon="book" patchable={false} />
          <Layouts.sidebar_link path="#" label="Second" icon="cube" selected patchable={false} />
        </Layouts.sidebar_section>
        <Layouts.sidebar_section title="Collapsed by default">
          <Layouts.sidebar_link path="#" label="Hidden until opened" icon="grid" patchable={false} />
        </Layouts.sidebar_section>
      </div>
      <p class="text-sm text-base-content/60">
        The section holding the current page opens itself: collapsing the section you
        are reading would hide your own location. Because the sidebar patches rather
        than remounts, whatever you collapse stays collapsed as you move between pages.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "sidebar-link"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The row that builds this page's own sidebar. A selected row carries <code>aria-current="page"</code>, so the current place is announced rather
        than only shaded.
      </p>
      <div class="docs-sidebar__section max-w-xs">
        <Layouts.sidebar_link path="#" label="Not selected" icon="book" patchable={false} />
        <Layouts.sidebar_link path="#" label="Selected" icon="cube" selected patchable={false} />
        <Layouts.sidebar_link path="#" label="Another row" icon="grid" patchable={false} />
      </div>
      <p class="text-sm text-base-content/60">
        <code>patchable</code>
        decides whether the row patches or navigates. Patching keeps the sidebar's DOM
        and therefore its scroll position; navigating remounts and sends the list back
        to the top. A row may patch only when the mounted LiveView already owns the
        target params.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "command-bar"}} = assigns) do
    ~H"""
    <Layouts.command_bar aria_label="Demo command bar" current_user={@demo_user}>
      <:lockup>
        <UI.badge variant={:dim}>demo</UI.badge>
      </:lockup>
      <:controls>
        <UI.text_button>Controls slot</UI.text_button>
      </:controls>
    </Layouts.command_bar>
    """
  end

  defp component_demo(%{item: %{slug: "account-control"}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="space-y-2">
        <p class="text-sm text-muted-foreground">Bar context</p>
        <Layouts.account_control current_user={@demo_user} context={:bar} />
      </div>
      <p class="text-sm text-muted-foreground max-w-[68ch]">
        Only one instance is shown. <code>account_control/1</code>
        hard-codes the ids <code>account-menu</code>, <code>account-menu-trigger</code>, <code>logout-form</code>, and <code>logout</code>, so it can be rendered at most
        once per page — rendering the <code>:row</code>
        context alongside this one produces duplicate ids. That is fine for a layout,
        which has a single account control, but it is a real constraint on reuse.
      </p>
    </div>
    """
  end

  # --- SCV graph -----------------------------------------------------------
  # The full state taxonomy is rendered here rather than described, so the
  # catalog page is the executable inventory of what each state looks like.

  defp component_demo(%{item: %{slug: "graph-node"}} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="space-y-2">
        <p class="text-sm text-base-content/60">
          SCV lifecycle — circle nodes. Ring style carries the state as well as hue.
        </p>
        <Graph.graph_surface view_box="0 0 460 78" label="SCV statuses" prefix="demo-scv">
          <Graph.graph_node
            :for={{status, i} <- Enum.with_index(Graph.statuses())}
            id={"demo-scv-#{status}"}
            shape={:circle}
            x={40.0 + i * 92}
            y={30.0}
            r={18.0}
            status={status}
            label={to_string(status)}
          />
        </Graph.graph_surface>
      </div>

      <div class="space-y-2">
        <p class="text-sm text-base-content/60">
          Work-item lifecycle — rect nodes, because a work item is inert data, not a
          running machine.
        </p>
        <Graph.graph_surface view_box="0 0 640 78" label="Work item statuses" prefix="demo-item">
          <Graph.graph_node
            :for={{status, i} <- Enum.with_index(Graph.item_statuses())}
            id={"demo-item-#{status}"}
            shape={:rect}
            x={44.0 + i * 90}
            y={30.0}
            width={44.0}
            height={30.0}
            status={status}
            label={to_string(status)}
          />
        </Graph.graph_surface>
      </div>

      <div class="space-y-2">
        <p class="text-sm text-base-content/60">Selected, and radius scaled by spend.</p>
        <Graph.graph_surface view_box="0 0 300 78" label="Node emphasis" prefix="demo-emph">
          <Graph.graph_node id="demo-sel" x={40.0} y={34.0} r={18.0} status={:running} selected />
          <Graph.graph_node id="demo-small" x={130.0} y={34.0} r={11.0} status={:running} />
          <Graph.graph_node id="demo-big" x={230.0} y={34.0} r={26.0} status={:running} />
        </Graph.graph_surface>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "graph-link"}} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="space-y-2">
        <p class="text-sm text-base-content/60">
          Every link kind. Distance is typed, so related things sit closer — the spacing
          here is each kind's own <code>link_distance/1</code>.
        </p>
        <Graph.graph_surface view_box="0 0 520 92" label="Link kinds" prefix="demo-kinds">
          <g :for={{kind, i} <- Enum.with_index(Graph.link_kinds())}>
            <Graph.graph_link
              id={"demo-link-#{kind}"}
              prefix="demo-kinds"
              source={%{shape: :circle, x: 34.0 + i * 104, y: 34.0, r: 13.0}}
              target={
                %{
                  shape: :rect,
                  x: 34.0 + i * 104 + 13.0 + Graph.link_distance(kind) + 11.0,
                  y: 34.0,
                  width: 22.0,
                  height: 16.0
                }
              }
              kind={kind}
            />
            <Graph.graph_node
              id={"demo-link-src-#{kind}"}
              x={34.0 + i * 104}
              y={34.0}
              r={13.0}
              status={:idle}
              label={to_string(kind)}
            />
            <Graph.graph_node
              id={"demo-link-tgt-#{kind}"}
              shape={:rect}
              x={34.0 + i * 104 + 13.0 + Graph.link_distance(kind) + 11.0}
              y={34.0}
              width={22.0}
              height={16.0}
              status={:admitted}
            />
          </g>
        </Graph.graph_surface>
      </div>

      <div class="space-y-2">
        <p class="text-sm text-base-content/60">
          A step traversing the link, and a labelled link. Terminations conform to the
          surface they touch: an arc into a circle, a flat bar into a rect.
        </p>
        <Graph.graph_surface
          view_box="0 0 320 92"
          label="Active and labelled links"
          prefix="demo-active"
        >
          <Graph.graph_link
            id="demo-link-active"
            prefix="demo-active"
            source={%{shape: :circle, x: 34.0, y: 34.0, r: 14.0}}
            target={%{shape: :rect, x: 150.0, y: 34.0, width: 24.0, height: 18.0}}
            kind={:normal}
            active
            label="step"
          />
          <Graph.graph_node id="demo-active-src" x={34.0} y={34.0} r={14.0} status={:running} />
          <Graph.graph_node
            id="demo-active-tgt"
            shape={:rect}
            x={150.0}
            y={34.0}
            width={24.0}
            height={18.0}
            status={:running}
          />
          <Graph.graph_link
            id="demo-link-back"
            prefix="demo-active"
            source={%{shape: :rect, x: 240.0, y: 34.0, width: 24.0, height: 18.0}}
            target={%{shape: :circle, x: 300.0, y: 34.0, r: 14.0}}
            kind={:normal}
          />
          <Graph.graph_node
            id="demo-back-src"
            shape={:rect}
            x={240.0}
            y={34.0}
            width={24.0}
            height={18.0}
            status={:completed}
          />
          <Graph.graph_node id="demo-back-tgt" x={300.0} y={34.0} r={14.0} status={:idle} />
        </Graph.graph_surface>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "scv-streams"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The swarm answers "how is the fleet"; this answers "what is it doing". A
        status ring can tell you an agent is running, but not that it has been
        rewriting the same test for four minutes.
      </p>
      <Graph.scv_streams scvs={@demo_streams} selected_id="scv-04" />
      <p class="text-sm text-base-content/60">
        Rows are a fixed height and the tail clips from the left, so a chatty agent
        cannot push the others off screen and the newest text stays visible.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "scv-swarm"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Fifteen SCVs at once. Position is derived from index, never from a mutable
        field, so "the third one down" keeps meaning the same agent.
      </p>
      <Graph.scv_swarm scvs={@demo_swarm} selected_id="scv-04" />
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-breadcrumb"}} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="space-y-2">
        <p class="text-sm text-base-content/60">
          A full trail. The last item is the current page, so it is text rather than a
          link — a link to the page you are already on is a dead control that still
          looks live.
        </p>
        <UI.breadcrumb>
          <:item navigate={~p"/"}>OpenAgents</:item>
          <:item navigate={~p"/components"}>Components</:item>
          <:item>Breadcrumb</:item>
        </UI.breadcrumb>
      </div>

      <div class="space-y-2">
        <p class="text-sm text-base-content/60">Two levels, and a lone root.</p>
        <UI.breadcrumb>
          <:item navigate={~p"/components"}>Components</:item>
          <:item>Badge</:item>
        </UI.breadcrumb>
        <UI.breadcrumb>
          <:item>OpenAgents</:item>
        </UI.breadcrumb>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-copy-button"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Click it. The glyph becomes a tick and the label changes for a moment, then
        returns — a copy control that changes nothing leaves you unsure it worked.
      </p>
      <UI.copy_button
        id="demo-copy-button"
        text="OpenAgentsWeb.UI.copy_button/1"
        label="Copy source"
      />
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "sidebar-footer"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The foot of every sidebar. Two of its rows are conditional: the component
        library is advertised outside production only, and Admin appears for an
        operator. Shown here with no user, so Admin is absent — which is what a
        visitor sees.
      </p>
      <div class="demo-frame">
        <Layouts.sidebar_footer />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-file-table"}} = assigns) do
    assigns =
      assign(assigns, :entries, [
        %{name: "assets", kind: "tree", size: nil},
        %{name: "config", kind: "tree", size: nil},
        %{name: "lib", kind: "tree", size: nil},
        %{name: "priv", kind: "tree", size: nil},
        %{name: "test", kind: "tree", size: nil},
        %{name: ".formatter.exs", kind: "blob", size: 412},
        %{name: "mix.exs", kind: "blob", size: 4_318},
        %{name: "README.md", kind: "blob", size: 1_204_291}
      ])

    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Takes what <code>Browse.tree/3</code> already returns. Directories sort above
        files, which is what makes a deep repository scannable: a reader looks for the
        folder first and only then for the file.
      </p>
      <p class="text-sm text-base-content/60">
        The latest commit sits above the table, not inside it. It describes the tree as
        a whole, and a row that describes the table while looking like a row in it is
        the part of GitHub's own version that reads oddly at first glance.
      </p>
      <UI.file_table
        owner="OpenAgentsInc"
        repo="openagents.com"
        ref="main"
        entries={@entries}
        branches={2}
        tags={0}
      >
        <:actions>
          <UI.button size={:sm}>Add file</UI.button>
          <UI.button variant={:primary} size={:sm}>Code</UI.button>
        </:actions>
        <:commit>
          <strong>AtlantisPleb</strong>
          <span>The commit page shows a diff instead of printing one</span>
          <code>57d5fd9</code>
          <span>15 minutes ago</span>
        </:commit>
      </UI.file_table>
      <p class="text-sm text-base-content/60">
        Per-row commit messages are deliberately absent: GitHub fills them by walking
        history once per path, which is one git process per file. When that is cheap the
        row has a slot for it and the markup does not change.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-repo-about"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Every row is optional and an absent one renders nothing. A rail that says
        "no description" is louder than one that simply does not mention it.
      </p>
      <div class="max-w-xs">
        <UI.repo_about description="The Agent Forge" license="AGPL-3.0">
          <:link icon="book" navigate="/docs">Readme</:link>
          <:link icon="text" navigate="/changelog">Activity</:link>
          <:stat icon="star">2 stars</:stat>
          <:stat icon="eye">0 watching</:stat>
          <:language percent={91.8}>Elixir</:language>
          <:language percent={3.1}>CSS</:language>
          <:language percent={3.1}>Shell</:language>
          <:language percent={1.0}>JavaScript</:language>
          <:language percent={1.0}>Other</:language>
        </UI.repo_about>
      </div>
      <p class="text-sm text-base-content/60">
        The language breakdown is one bar rather than a stack of them: the proportions
        are the point, and they only read as proportions when the segments share a
        length. Colours are a fixed six-step rotation off the ink ladder, so the chart
        stays in the palette instead of hashing a hue per language name.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-diff-file"}} = assigns) do
    assigns =
      assign(
        assigns,
        :files,
        OpenAgents.Diff.parse(~S"""
        diff --git a/lib/openagents/greeter.ex b/lib/openagents/greeter.ex
        index 1111111..2222222 100644
        --- a/lib/openagents/greeter.ex
        +++ b/lib/openagents/greeter.ex
        @@ -1,8 +1,9 @@ defmodule OpenAgents.Greeter do
         defmodule OpenAgents.Greeter do
        -  def hello(name) do
        -    "Hello, " <> name
        +  def hello(name) when is_binary(name) do
        +    "Hello, " <> name <> "!"
           end
        +
        +  def hello(_other), do: {:error, :not_a_name}
         end
        diff --git a/priv/static/logo.png b/priv/static/logo.png
        index 4415be7..d9aaa46 100644
        Binary files a/priv/static/logo.png and b/priv/static/logo.png differ
        diff --git a/lib/old/name.ex b/lib/new/name.ex
        similarity index 100%
        rename from lib/old/name.ex
        rename to lib/new/name.ex
        """)
      )

    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Takes an <code>OpenAgents.Diff.File</code>, which the parser produces from <code>git diff-tree -p -M</code>. Unified rather than split: a split view needs
        about twice the width to say the same thing, and the two number gutters already
        carry what it is for — which line this was, and which line it is now.
      </p>
      <p class="text-sm text-base-content/60">
        Every line with a new-side number is a link to itself, scoped by path, so a
        reader can point at a line instead of describing where it is. Click one and the
        row highlights. Colour is never the only signal: the marker column says <code>+</code>
        and <code>-</code>, so the diff survives greyscale.
      </p>
      <UI.diff_file :for={file <- @files} file={file} />
      <p class="text-sm text-base-content/60">
        The last two show the cases that are not code: a binary file, which says so
        rather than looking unchanged, and a rename with no content change.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-github-login"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A real form POST, because signing in starts an OAuth round-trip. Submitting
        swaps the mark for a spinner and disables the control: the round-trip leaves
        the page, so without it there is a window where the button looks idle and
        clickable while a redirect is already in flight, and a second click makes a
        second OAuth attempt. The pending state is also expressed for <code>:disabled</code>
        alone, so a browser restoring the page on
        back-navigation still shows the right thing.
      </p>
      <div class="flex flex-wrap items-center gap-3">
        <UI.github_login id="demo-github-login" />
        <UI.button variant={:primary} class="login-button" disabled>
          <UI.icon name="brand-github" class="login-button__mark" />
          <UI.icon name="circle-dashed" class="login-button__spinner" /> Log in with GitHub
        </UI.button>
      </div>
      <p class="text-sm text-base-content/60">
        The second is the pending state, shown by disabling it directly.
      </p>
    </div>
    """
  end

  # ── Landing ───────────────────────────────────────────────────────────────
  #
  # These demo at reduced scale inside the documentation column. A hero is
  # meant to own a viewport, so what a page here can honestly show is the
  # composition and the type ramp, not the impression.

  defp component_demo(%{item: %{slug: "landing-section"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The band every landing block sits in: horizontal padding, vertical rhythm that
        grows with the viewport, a centred measure, and a closing hairline. Sections are
        divided by a rule rather than by fill, so the page reads as one surface in parts.
      </p>
      <div class="demo-frame">
        <Landing.section>
          <p class="landing-heading">A section</p>
        </Landing.section>
        <Landing.section rule={false}>
          <p class="landing-heading">The last one, with no rule</p>
        </Landing.section>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-hero"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Eyebrow, headline, one line of prose, actions, and an optional figure lifted by a
        glow. The figure is a slot rather than an image attribute, so a page can frame a
        live surface instead of a screenshot of one.
      </p>
      <div class="demo-frame">
        <Landing.hero
          title="The Agent Forge"
          description="Purpose-built for planning and shipping issues. Designed for the agent era."
        >
          <:eyebrow>
            <UI.badge>New</UI.badge>
          </:eyebrow>
          <:actions>
            <UI.button variant={:primary}>Get started</UI.button>
            <UI.button>Read the docs</UI.button>
          </:actions>
          <:figure>
            <Landing.mockup>
              <div class="demo-screenshot">Your surface here</div>
            </Landing.mockup>
          </:figure>
        </Landing.hero>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-glow"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Two stacked ellipses — a wide faint wash under a narrower dense core. One
        gradient alone reads as a flat smudge; the pair reads as light. Decorative, so it
        is hidden from assistive technology, and it carries less intensity in light mode
        where the same value reads as a stain rather than a backdrop.
      </p>
      <div class="demo-glow-row">
        <div :for={variant <- [:top, :center, :bottom]} class="demo-glow">
          <Landing.glow variant={variant} />
          <span class="demo-glow__label">{variant}</span>
        </div>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-beam"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Where a glow is a band positioned against a section, a beam attaches to one
        element and blooms from it — for lighting a single figure rather than a region.
      </p>
      <div class="demo-glow-row">
        <Landing.beam :for={tone <- [:default, :bright]} tone={tone} class="demo-beam">
          <UI.badge>{tone}</UI.badge>
        </Landing.beam>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-mockup"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A second, wider border in a lighter fill is what reads as a device edge. Drawing
        a literal laptop dates the page and fixes the aspect ratio of whatever goes
        inside it.
      </p>
      <div class="demo-mockup-row">
        <Landing.mockup type={:window}>
          <div class="demo-screenshot">Window</div>
        </Landing.mockup>
        <Landing.mockup type={:phone} size={:large}>
          <div class="demo-screenshot demo-screenshot--tall">Phone</div>
        </Landing.mockup>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-feature-grid"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Four columns wide, two narrow. The cells carry no borders and no fills: a grid of
        boxes competes with itself for attention, and the alignment already separates
        them.
      </p>
      <div class="demo-frame">
        <Landing.feature_grid title="Everything the work needs">
          <:item title="Issues" icon="file-document">
            Plan, assign and close, with the same API shape you already use.
          </:item>
          <:item title="Projects" icon="grid">
            Group issues into work that has a beginning and an end.
          </:item>
          <:item title="Agents" icon="bolt">
            Durable workers that pick up an issue and see it through.
          </:item>
          <:item title="Receipts" icon="check-circle">
            Every run leaves evidence you can read afterwards.
          </:item>
        </Landing.feature_grid>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-stats"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The number is the largest thing in the cell. A statistic that has to be read to
        be understood is not doing the job a statistic is for. The suffix stays a
        separate element so the value and its unit can be sized apart.
      </p>
      <div class="demo-frame">
        <Landing.stats>
          <:stat label="over" value="1443">tests on every commit</:stat>
          <:stat label="under" value="7" suffix="s">to run the web suite</:stat>
          <:stat label="across" value="756">vendored glyphs</:stat>
          <:stat label="in" value="1">component system</:stat>
        </Landing.stats>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-pricing-column"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The price is a slot, not a number, so a column can say "Free" or "Usage-based"
        without this component holding an opinion about currency. The featured state is a
        brighter top rule and a lift — no accent fill and no scaling, which would make
        the other columns look broken rather than merely quieter.
      </p>
      <div class="demo-pricing-row">
        <Landing.pricing_column
          name="Open source"
          description="The whole application, AGPL-3.0."
          price="Free"
        >
          <:action><UI.button class="w-full">Clone it</UI.button></:action>
          <:feature>Every surface you see here</:feature>
          <:feature>Self-hosted, your database</:feature>
        </Landing.pricing_column>

        <Landing.pricing_column
          name="Hosted"
          description="The same thing, run for you."
          price="$20"
          price_note="/month"
          featured
        >
          <:action><UI.button variant={:primary} class="w-full">Start</UI.button></:action>
          <:feature>Managed database and backups</:feature>
          <:feature>Agents on our machines</:feature>
          <:feature>Usage receipts</:feature>
        </Landing.pricing_column>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-faq"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Native <code>&lt;details&gt;</code>, so the disclosure state lives in the element:
        no JavaScript, no ARIA to keep in sync, and keyboard behaviour is the browser's.
        A marketing page is the most likely thing to be read on a slow connection, so
        nothing here should wait on a bundle.
      </p>
      <div class="demo-frame">
        <Landing.faq title="Questions">
          <:item question="Is this really the whole application?" open>
            <p>Yes. The repository is AGPL-3.0 and this page is built from the same
              component system as every other surface.</p>
          </:item>
          <:item question="Does the accordion need JavaScript?">
            <p>No. It is a native disclosure element.</p>
          </:item>
        </Landing.faq>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-cta"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The closing ask. Its glow sits below the section rather than behind it and rises
        on hover, so the light reads as something under the fold rather than behind the
        text.
      </p>
      <div class="demo-frame">
        <Landing.cta
          title="Start shipping"
          description="Open an issue and let an agent pick it up."
        >
          <:actions>
            <UI.button variant={:primary}>Create an issue</UI.button>
          </:actions>
        </Landing.cta>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-logo-wall"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        One weight for every mark, so a heavier logo cannot dominate the row.
      </p>
      <div class="demo-frame">
        <Landing.logo_wall title="Built with">
          <:logo>Elixir</:logo>
          <:logo>Phoenix</:logo>
          <:logo>LiveView</:logo>
          <:logo>PostgreSQL</:logo>
        </Landing.logo_wall>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-footer"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A mark, a line about it, and columns of links.
      </p>
      <div class="demo-frame">
        <Landing.landing_footer
          tagline="Purpose-built for planning and shipping issues."
          note="AGPL-3.0. Every surface here is in the repository."
        >
          <:column title="Product">
            <.link navigate={~p"/docs"}>Documentation</.link>
            <.link navigate={~p"/components"}>Components</.link>
          </:column>
          <:column title="Transparency">
            <.link navigate={~p"/changelog"}>Changelog</.link>
            <.link navigate={~p"/status"}>Status</.link>
          </:column>
          <:column title="Work">
            <.link navigate={~p"/OpenAgentsInc/openagents.com/issues"}>Issues</.link>
          </:column>
        </Landing.landing_footer>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-layout-lines"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Faint dashed rules marking the content column's edges, fixed behind the page and
        pointer-transparent. Purely decorative: it gives a long marketing page a spine to
        read against, and removing it changes nothing about the content. Shown here
        contained rather than fixed, which is the one thing this demo cannot be honest
        about.
      </p>
      <div class="demo-frame demo-frame--lines">
        <Landing.layout_lines class="!absolute" />
        <p class="landing-heading">Content sits between them</p>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "issue-status"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Six categories, five of them a vendored glyph and one — <code>:started</code>
        — drawn in CSS from a percentage, because how far along the work is cannot come
        out of a fixed icon set. Colour is assigned per category off the same ladder
        <code>status_indicator/1</code>
        uses, so activity is blue and completion is green everywhere in the product.
      </p>
      <div class="flex flex-wrap gap-x-6 gap-y-3">
        <Circle.issue_status category={:triage} label="Triage" show_label />
        <Circle.issue_status category={:backlog} label="Backlog" show_label />
        <Circle.issue_status category={:unstarted} label="Todo" show_label />
        <Circle.issue_status category={:started} label="In progress" progress={35} show_label />
        <Circle.issue_status category={:started} label="In review" progress={70} show_label />
        <Circle.issue_status category={:completed} label="Done" show_label />
        <Circle.issue_status category={:canceled} label="Cancelled" show_label />
      </div>
      <p class="text-sm text-base-content/60">
        The arc at four fractions of the same shape:
      </p>
      <div class="flex flex-wrap gap-4">
        <Circle.issue_status
          :for={pct <- [0, 25, 50, 80]}
          category={:started}
          label={"#{pct}% complete"}
          progress={pct}
        />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "issue-priority"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The level reads from how much of the shape is lit, so the ordering survives
        greyscale. No priority is three dashes rather than the bottom of the ramp,
        because "nobody has decided" is not a degree of urgency, and urgent leaves the
        ramp entirely so the eye cannot skip it.
      </p>
      <div class="flex flex-wrap gap-x-6 gap-y-3">
        <Circle.issue_priority
          :for={level <- [:none, :low, :medium, :high, :urgent]}
          level={level}
          show_label
        />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "issue-label"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The source gives each label its own hex value chosen at creation. Six tones off
        the token ladder cannot tell eleven labels apart by colour, which is why the
        word here is never optional — the dot groups, it does not identify.
      </p>
      <div class="flex flex-wrap gap-2">
        <Circle.issue_label name="Bug" tone={:danger} />
        <Circle.issue_label name="Feature" tone={:success} />
        <Circle.issue_label name="Documentation" tone={:info} />
        <Circle.issue_label name="Refactor" tone={:warning} />
        <Circle.issue_label name="Design" tone={:primary} />
        <Circle.issue_label name="Testing" tone={:neutral} />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "assignee"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Unassigned is drawn rather than left blank: a gap in a column of faces reads as
        a rendering failure, and "nobody has picked this up" is one of the more
        actionable facts a triage view carries.
      </p>
      <div class="flex flex-wrap items-center gap-6">
        <Circle.assignee name="Mason Carter" presence={:online} show_name />
        <Circle.assignee name="Priya Raman" presence={:away} show_name />
        <Circle.assignee name="Ada Okafor" show_name />
        <Circle.assignee show_name />
      </div>
      <div class="flex flex-wrap items-center gap-6">
        <Circle.assignee
          :for={size <- [:sm, :default, :lg]}
          name="Jun Watanabe"
          size={size}
          presence={:online}
        />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "assignee-stack"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Overlapping faces say "a group"; the count says how big. Six faces without a
        count would claim the team has six people. Hover separates them so the
        individuals stay reachable.
      </p>
      <div class="flex flex-col gap-4">
        <Circle.assignee_stack people={@demo_people} limit={5} />
        <Circle.assignee_stack people={Enum.take(@demo_people, 3)} />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "issue-row"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Priority, identifier, and status lead in a fixed-width scan column, so they form
        a straight edge down the list instead of shifting with each title. The
        discretionary fields collect at the trailing edge and drop by width from the
        least load-bearing inwards; the scan column and the title never drop.
      </p>
      <div class="-mx-6 border-y border-border">
        <Circle.issue_row
          :for={issue <- @demo_issues}
          identifier={issue.identifier}
          title={issue.title}
          status_category={issue.status_category}
          status_label={issue.status_label}
          progress={issue[:progress]}
          priority={issue.priority}
          labels={issue.labels}
          project={issue[:project]}
          due={issue[:due]}
          created={issue.created}
          assignee={issue.assignee}
        />
      </div>
      <p class="text-sm text-base-content/60">Selected, and with a destination on the title:</p>
      <div class="-mx-6 border-y border-border">
        <Circle.issue_row
          identifier="OA-142"
          title="Placement refuses a node whose capability manifest has expired"
          navigate={~p"/components/issue-row"}
          status_category={:started}
          status_label="In progress"
          progress={35}
          priority={:urgent}
          selected
          assignee={%{name: "Mason Carter", presence: :online}}
        />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "issue-card"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A card is not a row turned sideways. With width and no neighbours the title gets
        two lines, the labels get their own band, and the assignee drops to the foot
        where it reads as ownership of the card rather than one more trailing attribute.
      </p>
      <div class="grid gap-3 sm:grid-cols-2">
        <Circle.issue_card
          :for={issue <- Enum.take(@demo_issues, 4)}
          identifier={issue.identifier}
          title={issue.title}
          status_category={issue.status_category}
          status_label={issue.status_label}
          progress={issue[:progress]}
          priority={issue.priority}
          labels={issue.labels}
          project={issue[:project]}
          created={issue.created}
          assignee={issue.assignee}
        />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "issue-group"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The header sticks and carries a wash mixed from its own category, which is the
        only thing that says where one group ends once the header has scrolled past its
        rows. The wash is mixed over the canvas rather than laid on with alpha, so rows
        passing underneath are covered instead of showing through.
      </p>
      <div class="-mx-6 max-h-80 overflow-y-auto border-y border-border">
        <Circle.issue_group
          :for={
            {category, label} <- [
              {:started, "In progress"},
              {:unstarted, "Todo"},
              {:backlog, "Backlog"}
            ]
          }
          label={label}
          category={category}
          count={Enum.count(@demo_issues, &(&1.status_category == category))}
        >
          <:glyph>
            <Circle.issue_status category={category} label={label} progress={35} />
          </:glyph>
          <:actions>
            <UI.text_button aria-label={"Add an issue to #{label}"}>
              <UI.icon name="plus" />
            </UI.text_button>
          </:actions>
          <Circle.issue_row
            :for={issue <- Enum.filter(@demo_issues, &(&1.status_category == category))}
            identifier={issue.identifier}
            title={issue.title}
            status_category={issue.status_category}
            status_label={issue.status_label}
            progress={issue[:progress]}
            priority={issue.priority}
            labels={issue.labels}
            created={issue.created}
            assignee={issue.assignee}
          />
          <UI.empty
            :if={Enum.all?(@demo_issues, &(&1.status_category != category))}
            title="Nothing here"
          >
            No issue is in this state.
          </UI.empty>
        </Circle.issue_group>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "issue-board"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Columns side by side, each scrolling on its own — scrolling the board as one
        surface would push every header off the top to read the bottom of one column.
        The source adds drag-and-drop over this layout; the layout is the part worth
        having on a server-rendered page.
      </p>
      <div class="h-96">
        <Circle.issue_board class="h-full">
          <Circle.issue_group
            :for={
              {category, label} <- [
                {:started, "In progress"},
                {:unstarted, "Todo"},
                {:completed, "Done"}
              ]
            }
            layout={:board}
            label={label}
            category={category}
            count={Enum.count(@demo_issues, &(&1.status_category == category))}
          >
            <:glyph>
              <Circle.issue_status category={category} label={label} progress={35} />
            </:glyph>
            <Circle.issue_card
              :for={issue <- Enum.filter(@demo_issues, &(&1.status_category == category))}
              identifier={issue.identifier}
              title={issue.title}
              status_category={issue.status_category}
              status_label={issue.status_label}
              progress={issue[:progress]}
              priority={issue.priority}
              labels={issue.labels}
              created={issue.created}
              assignee={issue.assignee}
            />
          </Circle.issue_group>
        </Circle.issue_board>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "filter-chip"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Subject, operator, value, each its own segment. That division is what lets <code>is</code>
        become <code>is not</code>
        without the filter being removed and rebuilt, and it is what the source's filter
        library spends most of its code on.
      </p>
      <div class="flex flex-wrap gap-2">
        <Circle.filter_chip
          subject="Status"
          operator="is any of"
          value="In progress, Todo"
          icon="circle"
        />
        <Circle.filter_chip subject="Assignee" operator="is" value="Mason Carter" icon="user" />
        <Circle.filter_chip
          subject="Label"
          operator="is not"
          value="Documentation"
          icon="tag"
          on_remove={JS.hide(to: {:closest, ".filter-chip"})}
        />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "filter-bar"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The applied filters, the control that adds one, and a way to drop them all. The
        source hides this row entirely until a filter exists and keeps the entry point
        in the toolbar, which is right — an empty filter bar is a permanent reminder of
        a feature nobody is using. Rendering nothing when there are no chips stays the
        caller's decision.
      </p>
      <div class="-mx-6">
        <Circle.filter_bar on_clear={JS.hide(to: {:closest, ".filter-bar"})}>
          <:add>
            <UI.text_button><UI.icon name="filter" /> Filter</UI.text_button>
          </:add>
          <Circle.filter_chip
            subject="Status"
            operator="is any of"
            value="In progress, Todo"
            icon="circle"
            on_remove={JS.hide(to: {:closest, ".filter-chip"})}
          />
          <Circle.filter_chip
            subject="Priority"
            operator="is"
            value="Urgent"
            icon="bar-chart"
            on_remove={JS.hide(to: {:closest, ".filter-chip"})}
          />
        </Circle.filter_bar>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "view-tabs"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Pills rather than underlined tabs: these switch a filter, not a page, and an
        underline promises a bigger change than actually happens. The current view
        carries <code>aria-current</code>, so its state is not colour alone.
      </p>
      <Circle.view_tabs label="Issue views">
        <:tab label="Active" navigate={~p"/components/view-tabs"} selected />
        <:tab label="Backlog" navigate={~p"/components/view-tabs"} />
        <:tab label="All issues" navigate={~p"/components/view-tabs"} />
      </Circle.view_tabs>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "issue-toolbar"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        What you are looking at on the left, what you can do to it on the right. The
        source splits this into two stacked rows; stacking two toolbars gives the same
        arrangement without forcing a surface that has only options to carry an empty
        navigation strip.
      </p>
      <div class="-mx-6">
        <Circle.issue_toolbar>
          <:leading>
            <Circle.view_tabs label="Issue views">
              <:tab label="Active" navigate={~p"/components/issue-toolbar"} selected />
              <:tab label="Backlog" navigate={~p"/components/issue-toolbar"} />
            </Circle.view_tabs>
          </:leading>
          <:actions>
            <UI.text_button aria-label="Search issues"><UI.icon name="search" /></UI.text_button>
            <UI.text_button aria-label="Notifications"><UI.icon name="bell" /></UI.text_button>
          </:actions>
        </Circle.issue_toolbar>
        <Circle.issue_toolbar>
          <:leading>
            <span class="text-xs text-muted-foreground">6 issues</span>
          </:leading>
          <:actions>
            <UI.text_button><UI.icon name="filter" /> Filter</UI.text_button>
            <UI.text_button><UI.icon name="settings-slider" /> Display</UI.text_button>
          </:actions>
        </Circle.issue_toolbar>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "command-palette"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Press
        <UI.kbd>⌘</UI.kbd>
        <UI.kbd>K</UI.kbd>
        or use the button. A native <code>&lt;dialog&gt;</code>
        supplies the focus trap, the backdrop, and <UI.kbd>Esc</UI.kbd>; the one
        colocated hook adds the shortcut, incremental filtering, and arrow-key
        selection, which are the four things markup cannot express. Every command is a
        real button and works without the hook.
      </p>
      <UI.button data-command-target="demo-command-palette">Open the palette</UI.button>
      <Circle.command_palette
        id="demo-command-palette"
        context="OA-142 · Placement refuses an expired manifest"
      >
        <Circle.command_group heading="Issue">
          <Circle.command_item label="Assign to…" icon="user-add" keys={["A"]} />
          <Circle.command_item label="Change status…" icon="circle" keys={["S"]} />
          <Circle.command_item label="Set priority…" icon="bar-chart" keys={["P"]} />
          <Circle.command_item label="Change or add labels…" icon="tag" keys={["L"]} />
          <Circle.command_item label="Set due date…" icon="calendar" keys={["⇧", "D"]} />
        </Circle.command_group>
        <Circle.command_group heading="Copy">
          <Circle.command_item label="Copy issue ID" icon="clipboard" keys={["⌘", "."]} />
          <Circle.command_item label="Copy issue URL" icon="link" keys={["⌘", "⇧", ","]} />
          <Circle.command_item label="Copy branch name" icon="branch" keys={["⌘", "⇧", "."]} />
        </Circle.command_group>
        <Circle.command_group heading="Go to">
          <Circle.command_item label="My issues" icon="user" keys={["G", "I"]} />
          <Circle.command_item label="Projects" icon="cube" keys={["G", "P"]} />
          <Circle.command_item label="Teams" icon="members" keys={["G", "T"]} />
        </Circle.command_group>
      </Circle.command_palette>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "command-group"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Headings keep a palette of forty commands readable, and they are what makes
        filtering legible: a group whose commands have all been filtered out hides
        itself rather than leaving a heading over a gap. Shown here outside a dialog so
        the structure is visible.
      </p>
      <div class="command-palette__list rounded-lg border border-border">
        <Circle.command_group heading="Issue">
          <Circle.command_item label="Assign to…" icon="user-add" keys={["A"]} />
          <Circle.command_item label="Change status…" icon="circle" keys={["S"]} />
        </Circle.command_group>
        <Circle.command_group heading="Copy">
          <Circle.command_item label="Copy issue ID" icon="clipboard" keys={["⌘", "."]} />
        </Circle.command_group>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "command-item"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A glyph, a name, and the keys that reach it directly. The chips are
        documentation rather than bindings — the palette does not install them. Showing
        them anyway is how a person stops needing the palette, which is the point of
        having one. The label doubles as the filter key.
      </p>
      <div class="command-palette__list rounded-lg border border-border">
        <Circle.command_item label="Assign to…" icon="user-add" keys={["A"]} />
        <Circle.command_item label="Copy issue URL" icon="link" keys={["⌘", "⇧", ","]} />
        <Circle.command_item label="Create new issue" icon="plus" />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "project-row"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Projects are read across rather than down — the question is which one is behind,
        not what any one of them is called — so the trailing fields sit in fixed columns
        that line up between rows. Health is a word: "at risk" and "off track" are
        different claims, and no reader should have to learn which shade of amber means
        which.
      </p>
      <div class="-mx-6 border-y border-border">
        <Circle.project_row
          name="Managed nodes"
          health={:on_track}
          priority={:high}
          lead={%{name: "Priya Raman"}}
          target="Sep 30"
          issues={24}
          status_category={:started}
          status_label="In progress"
          percent={62}
          labels={[%{name: "Cloud", tone: :info}]}
        />
        <Circle.project_row
          name="Component library"
          navigate={~p"/components"}
          health={:at_risk}
          priority={:medium}
          lead={%{name: "Ada Okafor"}}
          target="Aug 29"
          issues={11}
          status_category={:started}
          status_label="In progress"
          percent={78}
        />
        <Circle.project_row
          name="Taproot settlement"
          health={:off_track}
          priority={:urgent}
          target="Oct 14"
          issues={7}
          status_category={:triage}
          status_label="Triage"
        />
        <Circle.project_row
          name="Second theme selector"
          priority={:none}
          issues={0}
          status_category={:canceled}
          status_label="Cancelled"
        />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "team-row"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The identifier sits beside the name rather than instead of it, because it is the
        prefix on every issue key the team produces — <code>OA-142</code>
        is only findable if somebody can connect <code>OA</code>
        to a team.
      </p>
      <div class="-mx-6 border-y border-border">
        <Circle.team_row
          name="Core"
          identifier="OA"
          glyph="◆"
          navigate={~p"/components/team-row"}
          joined
          members={@demo_people}
          projects={6}
          cycles={3}
        />
        <Circle.team_row
          name="Cloud"
          identifier="CLD"
          glyph="▲"
          members={Enum.take(@demo_people, 4)}
          projects={3}
          cycles={2}
        />
        <Circle.team_row
          name="Design"
          identifier="DSN"
          members={Enum.take(@demo_people, 2)}
          projects={1}
        />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "member-row"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Two lines of identity rather than one. A display name is what a colleague
        recognises and a handle is what appears in a mention; a directory that shows
        only one of them fails whichever question is being asked.
      </p>
      <div class="-mx-6 border-y border-border">
        <Circle.member_row
          name="Mason Carter"
          handle="mason.carter"
          navigate={~p"/components/member-row"}
          role="Admin"
          role_tone={:accent}
          joined="Mar 2024"
          teams={["OA", "CLD", "DSN"]}
          presence={:online}
        />
        <Circle.member_row
          name="Priya Raman"
          handle="priya.raman"
          role="Member"
          joined="Jun 2024"
          teams={["OA"]}
          presence={:away}
        />
        <Circle.member_row name="forge-bot" handle="forge.bot" role="Application" joined="Jan 2025" />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "issue-state"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        <code>issue_status/1</code>
        renders six categories because Circle has six. GitHub has two, and the ruling in
        <code>docs/2026-08-20-linear-design-github-shape.md</code>
        is that we have what GitHub has. This is the narrower component every
        GitHub-shaped surface reaches for: it takes the payload's own <code>state</code>
        and <code>state_reason</code>
        and maps them once, here, so two pages cannot disagree about what closed looks
        like.
      </p>
      <div class="flex flex-wrap gap-x-6 gap-y-3">
        <Circle.issue_state state="open" show_label />
        <Circle.issue_state state="closed" reason="completed" show_label />
        <Circle.issue_state state="closed" reason="not_planned" show_label />
        <Circle.issue_state state="closed" reason="duplicate" show_label />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "issue-detail"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A heading band, the work, and a properties rail. Circle hides the rail below <code>lg</code>; state, labels and assignees are not decoration and a phone is
        where an issue is most often read, so here the rail moves under the heading on a
        narrow screen and to the side when there is room. Resize to see it.
      </p>
      <div class="demo-frame">
        <Circle.issue_detail>
          <:heading>
            <h2 class="text-2xl font-semibold">Wire the issue list to the ported row component</h2>
            <p class="mt-2 flex items-center gap-2 text-sm text-muted-foreground">
              <Circle.issue_state state="open" show_label /> · opened 2d ago by ada
            </p>
          </:heading>
          <:rail>
            <Circle.properties_panel>
              <:group heading="Assignees">
                <Circle.assignee name="Mason Carter" show_name size={:sm} />
              </:group>
              <:group heading="Labels">
                <Circle.issue_label name="Design" tone={:primary} />
              </:group>
            </Circle.properties_panel>
          </:rail>
          <p class="text-sm text-muted-foreground">
            The description, then the timeline, held to a measure rather than the window.
          </p>
        </Circle.issue_detail>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "properties-panel"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The source's panel carries status, priority, cycle, project, relations and linked
        diffs. All but state, labels, assignees and milestone are dropped: GitHub has no
        field for them. A group renders even when empty, which is the one departure from
        what this page used to do — a field you cannot see is a field you cannot set, and
        these are editable now.
      </p>
      <div class="max-w-xs rounded-lg border border-border p-4">
        <Circle.properties_panel>
          <:group heading="State">
            <Circle.issue_state state="open" show_label />
          </:group>
          <:group heading="Assignees">
            <Circle.assignee name="Priya Raman" show_name size={:sm} />
          </:group>
          <:group heading="Labels">
            <Circle.issue_label name="Bug" tone={:danger} />
            <Circle.issue_label name="Cloud" tone={:info} />
          </:group>
          <:group heading="Milestone">
            <span class="properties-panel__none">No milestone</span>
          </:group>
        </Circle.properties_panel>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "timeline"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        An ordered list, because the sequence is the meaning. A hairline runs behind the
        glyph column: Circle draws no line and its feed reads as loose rows, and the line
        is what turns a run of facts into one history.
      </p>
      <Circle.timeline>
        <Circle.timeline_event actor="ada" text="opened this issue" icon="plus-circle" at="2d ago" />
        <Circle.timeline_event actor="ada" text="added the" icon="tag" at="2d ago">
          <Circle.issue_label name="Bug" tone={:danger} /> label
        </Circle.timeline_event>
        <Circle.timeline_comment
          id="demo-timeline-comment"
          author="Mason Carter"
          at="1d ago"
          badge="Author"
        >
          <p>Reproduced on staging. The row renders but the state glyph is inert.</p>
        </Circle.timeline_comment>
        <Circle.timeline_event
          actor="mason"
          text="closed this as completed"
          icon="check-circle-filled"
          tone={:success}
          at="4h ago"
        />
      </Circle.timeline>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "timeline-event"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        An event is deliberately quieter than a comment: it is a fact about the issue
        rather than something a person wrote, and giving them the same weight makes a
        thread of six label changes and one real comment look like seven comments. The
        text is the predicate only — the actor is already the subject, and repeating the
        name inside the sentence reads as a template nobody filled in.
      </p>
      <Circle.timeline>
        <Circle.timeline_event actor="ada" text="opened this issue" icon="plus-circle" at="2d ago" />
        <Circle.timeline_event
          actor="ada"
          text="assigned this to mason"
          icon="user-add"
          tone={:info}
          at="2d ago"
        />
        <Circle.timeline_event
          actor="mason"
          text="closed this as completed"
          icon="check-circle-filled"
          tone={:success}
          at="4h ago"
        />
        <Circle.timeline_event
          actor="mason"
          text="closed this as not planned"
          icon="x-circle-filled"
          tone={:danger}
          at="4h ago"
        />
      </Circle.timeline>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "timeline-comment"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A card against the events' single lines; the contrast is what keeps a long thread
        scannable. <code>badge</code>
        is what GitHub prints beside a name — <strong>Author</strong>, <strong>Member</strong>,
        <strong>Owner</strong>
        — which GitHub derives by comparing the commenter to the issue's author rather
        than storing it, so this takes a string the caller worked out.
      </p>
      <Circle.timeline>
        <Circle.timeline_comment id="demo-comment-author" author="ada" at="2d ago" badge="Author">
          <p>The list renders but nothing in the row responds to a click.</p>
        </Circle.timeline_comment>
        <Circle.timeline_comment id="demo-comment-plain" author="Mason Carter" at="1d ago">
          <p>
            Fixed by making the state glyph a <code>field_menu/1</code> trigger.
          </p>
        </Circle.timeline_comment>
      </Circle.timeline>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "comment-composer"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        What makes it deliberate rather than a bare textarea is that the whole well is the
        control: the border, the writer's face, and the footer are one surface that takes
        focus as a unit. The text control and the submit action are slots, because this
        lives inside the caller's form — the composer owns the shape, the form owns the
        data.
      </p>
      <.form for={@form} id="demo-composer-form" phx-submit="save">
        <Circle.comment_composer id="demo-composer" author="Demo Account">
          <.input field={@form[:body]} type="textarea" label="Comment" placeholder="Leave a comment" />
          <:hint>Markdown is supported.</:hint>
          <:actions>
            <UI.button type="submit" variant={:primary} size={:sm}>Comment</UI.button>
          </:actions>
        </Circle.comment_composer>
      </.form>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "field-menu"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        This is what Circle's rows have that ours did not: the value is the control.
        Circle wraps a Radix dropdown around a <code>cmdk</code>
        list; a native popover gives the same behaviour — click out to dismiss,
        <UI.kbd>Esc</UI.kbd>
        to close, the trigger as the anchor — with no script, and the trigger is a real
        button so the keyboard reaches it for free. The trigger is a slot, so what you
        click is the glyph itself rather than a control beside it.
      </p>
      <div class="flex items-center gap-6">
        <Circle.field_menu id="demo-state-menu" label="Change state">
          <:trigger><Circle.issue_state state="open" /></:trigger>
          <Circle.field_menu_item label="Open" mode={:choice} selected closes="demo-state-menu">
            <:glyph><Circle.issue_state state="open" /></:glyph>
          </Circle.field_menu_item>
          <Circle.field_menu_item label="Closed as completed" mode={:choice} closes="demo-state-menu">
            <:glyph><Circle.issue_state state="closed" reason="completed" /></:glyph>
          </Circle.field_menu_item>
          <Circle.field_menu_item
            label="Closed as not planned"
            mode={:choice}
            closes="demo-state-menu"
          >
            <:glyph><Circle.issue_state state="closed" reason="not_planned" /></:glyph>
          </Circle.field_menu_item>
        </Circle.field_menu>

        <Circle.field_menu id="demo-assignee-menu" label="Assign this issue">
          <:trigger><Circle.assignee name="Mason Carter" /></:trigger>
          <Circle.field_menu_item
            :for={person <- @demo_people}
            label={person.name}
            selected={person.name == "Mason Carter"}
          >
            <:glyph><Circle.assignee name={person.name} size={:sm} /></:glyph>
          </Circle.field_menu_item>
        </Circle.field_menu>

        <Circle.field_menu id="demo-label-menu" label="Change labels" align={:end}>
          <:trigger><UI.icon name="tag" class="size-4" /></:trigger>
          <Circle.field_menu_item label="Bug" selected>
            <:glyph><span class="issue-label__dot" data-tone="danger" /></:glyph>
          </Circle.field_menu_item>
          <Circle.field_menu_item label="Cloud">
            <:glyph><span class="issue-label__dot" data-tone="info" /></:glyph>
          </Circle.field_menu_item>
        </Circle.field_menu>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "field-menu-item"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        <code>mode</code>
        decides what the option claims. Labels and assignees are a set, so each option is
        a toggle and says <code>aria-pressed</code>; state and milestone are one choice
        out of several, so the selected one says <code>aria-current</code>. Both draw the
        same tick, because it means the same thing to a reader either way. The tick keeps
        its column when absent, so words do not shift.
      </p>
      <div class="menu !static max-w-xs p-1">
        <Circle.field_menu_item label="Bug" selected />
        <Circle.field_menu_item label="Documentation" icon="book" />
        <Circle.field_menu_item label="Closed as completed" mode={:choice} selected>
          <:glyph><Circle.issue_state state="closed" reason="completed" /></:glyph>
        </Circle.field_menu_item>
        <Circle.field_menu_item label="Closed as not planned" mode={:choice}>
          <:glyph><Circle.issue_state state="closed" reason="not_planned" /></:glyph>
        </Circle.field_menu_item>
      </div>
    </div>
    """
  end

  # The breadcrumb names the section a component lives in, so the trail matches
  # the sidebar the reader navigated through.
  defp section_title_for(slug) do
    Enum.find_value(ComponentCatalog.sections(), fn section ->
      if Enum.any?(section.items, &(&1.slug == slug)), do: section.title
    end)
  end
end
