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
  alias OpenAgentsWeb.UI.Graph
  alias OpenAgentsWeb.UI, as: UI

  @sample_rows [
    %{id: 1, owner: "OpenAgentsInc", repo: "openagents.com", state: "open"},
    %{id: 2, owner: "OpenAgentsInc", repo: "openagents.com", state: "open"},
    %{id: 3, owner: "OpenAgentsInc", repo: "arcade", state: "closed"}
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
     |> assign(:demo_streams, @demo_streams)}
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

  # The breadcrumb names the section a component lives in, so the trail matches
  # the sidebar the reader navigated through.
  defp section_title_for(slug) do
    Enum.find_value(ComponentCatalog.sections(), fn section ->
      if Enum.any?(section.items, &(&1.slug == slug)), do: section.title
    end)
  end
end
