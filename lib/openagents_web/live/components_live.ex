defmodule OpenAgentsWeb.ComponentsLive do
  @moduledoc """
  Public catalog of reusable HEEx components that ship in this codebase.

  `/components` is an index; each component gets its own page at
  `/components/:slug`. The sidebar and the set of valid slugs both come from
  `OpenAgentsWeb.ComponentCatalog`, so navigation and pages cannot drift.

  Planned forge and issues components are listed in `docs/component-library.md`.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgentsWeb.AI.Conversation
  alias OpenAgentsWeb.AI.Evidence
  alias OpenAgentsWeb.AI.PromptInput
  alias OpenAgentsWeb.AI.Reasoning
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

  # This repository's own root, in the order `Browse.tree/3` returns it:
  # directories above files, each group by name. The message and age on a row
  # are what `git log -1 -- <path>` says about that path, and the sizes are the
  # real ones. The composed repository demo is only worth reading if the
  # composition is carrying real proportions -- invented data makes every
  # column look comfortable.
  @demo_repo_entries [
    %{
      name: "assets",
      kind: "tree",
      size: nil,
      message: "Delete the CONNECTED bar from the conversation",
      updated: "3 hours ago"
    },
    %{
      name: "config",
      kind: "tree",
      size: nil,
      message: "Connect staging fleet through Cloud SQL Auth Proxy",
      updated: "1 hour ago"
    },
    %{
      name: "docs",
      kind: "tree",
      size: nil,
      message: "Specify repository creation and the OpenAgents CLI",
      updated: "18 minutes ago"
    },
    %{
      name: "infra",
      kind: "tree",
      size: nil,
      message: "Connect staging fleet through Cloud SQL Auth Proxy",
      updated: "1 hour ago"
    },
    %{
      name: "lib",
      kind: "tree",
      size: nil,
      message: "Group the agent's surfaces under her name",
      updated: "15 minutes ago"
    },
    %{
      name: "priv",
      kind: "tree",
      size: nil,
      message: "Restore the power mark from v4 and v5 as the favicon",
      updated: "3 hours ago"
    },
    %{
      name: "test",
      kind: "tree",
      size: nil,
      message: "Give the modal scrim a token, and drop the guard's exception",
      updated: "5 hours ago"
    },
    %{
      name: ".formatter.exs",
      kind: "blob",
      size: 225,
      message: "Initialize Phoenix 1.8 application with latest dependencies",
      updated: "yesterday"
    },
    %{
      name: "AGENTS.md",
      kind: "blob",
      size: 28_064,
      message: "Authorize the theme bootstrap with a CSP nonce",
      updated: "9 hours ago"
    },
    %{
      name: "mix.exs",
      kind: "blob",
      size: 4_252,
      message: "Publish immutable staging candidate artifacts",
      updated: "9 hours ago"
    },
    %{
      name: "README.md",
      kind: "blob",
      size: 5_527,
      message: "Build isolated staging infrastructure",
      updated: "10 hours ago"
    }
  ]

  # One call per tool state. `tool_status_badge/1` is the taxonomy, so the page
  # that demonstrates a tool call has to walk all seven; a single successful
  # call would document the one state nobody needs help reading.
  @demo_tool_calls [
    %{
      state: "input-streaming",
      name: "grep",
      input: ~s({"pattern": "capability_manifest", "path": "lib/openage),
      output: nil,
      error: nil
    },
    %{
      state: "input-available",
      name: "read",
      input: ~s({"path": "lib/openagents/cloud/placement.ex", "offset": 1, "limit": 120}),
      output: nil,
      error: nil
    },
    %{
      state: "output-available",
      name: "bash",
      input: ~s({"command": "mix test test/openagents/forge/targets_test.exs --seed 0"}),
      output: "Finished in 2.4 seconds\n1416 tests, 0 failures, 14 excluded",
      error: nil
    },
    %{
      state: "output-error",
      name: "bash",
      input: ~s({"command": "mix precommit"}),
      output: nil,
      error: "** (Mix) Formatter would change lib/openagents_web/live/chat_live.ex"
    },
    %{
      state: "approval-requested",
      name: "write",
      input: ~s({"path": "lib/openagents/forge/targets.ex", "bytes": 4213}),
      output: nil,
      error: nil
    },
    %{
      state: "approval-responded",
      name: "write",
      input: ~s({"path": "lib/openagents/forge/targets.ex", "bytes": 4213}),
      output: "Approved by mason. 3 hunks written.",
      error: nil
    },
    %{
      state: "output-denied",
      name: "bash",
      input: ~s({"command": "git push openagents HEAD:main"}),
      output: nil,
      error: "Denied by mason: this run is not allowed to push."
    }
  ]

  # Real Elixir rather than a fragment, so the line-number gutter and the
  # horizontal overflow are both exercised the way they will be in use.
  @demo_code """
  def admit(%Run{} = run, fleet) do
    with :ok <- Capability.fresh?(run.manifest),
         {:ok, node} <- Placement.choose(fleet, run.requirements) do
      {:ok, %{run | node: node, admitted_at: DateTime.utc_now()}}
    else
      {:error, :manifest_expired} = error -> error
      {:error, reason} -> {:error, {:unplaceable, reason}}
    end
  end
  """

  @demo_terminal_output """
  $ mix test test/openagents/forge/targets_test.exs --seed 0
  Running ExUnit with seed: 0, max_cases: 20

  ....................

  Finished in 2.4 seconds (0.9s async, 1.5s sync)
  20 tests, 0 failures

  $ mix test test/openagents/forge/targets_test.exs --seed 1
  Running ExUnit with seed: 1, max_cases: 20

  ......F.............
  """

  # Everyone `git shortlog -sn` names on this repository, most commits first.
  @demo_repo_contributors [%{name: "AtlantisPleb"}, %{name: "Christopher David"}]

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

    # The composer is a real `to_form/2` assign, because that is the only way
    # `prompt_input_textarea/1` can be bound to a field rather than a string.
    composer_form =
      to_form(%{"message" => "Which module decides whether an SCV run is admitted?"},
        as: :composer
      )

    {:ok,
     socket
     |> assign(:form, form)
     |> assign(:composer_form, composer_form)
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

  # `speech_input/1` requires the name of an event to push recognized text to.
  # Without a matching clause the catalog page would crash the first time
  # someone spoke into it, which is a worse demo than no demo.
  def handle_event("demo_transcript", %{"text" => text}, socket) do
    {:noreply, assign(socket, :composer_form, to_form(%{"message" => text}, as: :composer))}
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <div id="components-index">
      <h1 class="text-3xl font-semibold mb-4">Component library</h1>
      <p class="text-muted-foreground mb-8 text-pretty max-w-[68ch]">
        Live examples of every supported function component in <code>OpenAgentsWeb.UI</code>, <code>OpenAgentsWeb.Layouts</code>, the surface modules beside them, and the
        repository header. A test asserts this page covers every public component
        in those modules. The <code>OpenAgentsWeb.AI</code>
        sections are catalogued one entry per family, so a page there shows a
        whole composition rather than one of its parts.
        Planned GitHub-shaped components are listed in <code>docs/component-library.md</code>.
      </p>

      <section :for={section <- ComponentCatalog.sections()} class="mb-10">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-muted-foreground mb-3">
          {section.title}
        </h2>
        <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
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
    <%!-- The page fills its column and the prose caps itself. Capping the page
    capped the demo too, which is the one thing on it that wants the room: a
    composed surface squeezed into a reading measure stops demonstrating the
    proportions it exists to show. --%>
    <div id={"component-#{@item.slug}"} class="space-y-6">
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
  attr :composer_form, :any, default: nil
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

  defp component_demo(%{item: %{slug: "openagents-time-ago"}} = assigns) do
    ~H"""
    <ul class="space-y-2 text-sm text-muted-foreground">
      <li>
        Pushed <UI.time_ago at={DateTime.add(DateTime.utc_now(), -240, :second)} />
      </li>
      <li>
        Pushed <UI.time_ago at={DateTime.add(DateTime.utc_now(), -4 * 3_600, :second)} />
      </li>
      <li>
        Pushed <UI.time_ago at={DateTime.add(DateTime.utc_now(), -9 * 86_400, :second)} />
      </li>
    </ul>
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
      Work you delegate to a paired computer will appear here.
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
          running state machine.
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
        <Layouts.sidebar_footer current_user={nil} />
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

  defp component_demo(%{item: %{slug: "openagents-repo-tabs"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Seven links, not seven tabs. Each one changes the URL, so the selected entry
        is marked with <code>aria-current="page"</code>
        and the underline follows that attribute. Giving these a tab role would promise
        panels that swap in place, and a reader who accepted the promise and reached for
        the arrow keys would get nothing.
      </p>
      <UI.repo_tabs>
        <:tab icon="code" href="#code" current>Code</:tab>
        <:tab icon="empty-circle" href="#issues" count={12}>Issues</:tab>
        <:tab icon="pull-request-open" href="#pulls" count={3}>Pull requests</:tab>
        <:tab icon="cube" href="#projects">Projects</:tab>
        <:tab icon="book-open" href="#wiki">Wiki</:tab>
        <:tab icon="chart" href="#insights">Insights</:tab>
        <:tab icon="settings-cog" href="#settings">Settings</:tab>
      </UI.repo_tabs>
      <p class="text-sm text-base-content/60">
        The count sits in its own element rather than inside the word, so "Issues" stays
        findable by that word alone, the number keeps its own weight, and a narrow screen
        can drop it without anyone rewriting the label. The destinations here are page
        anchors, because the catalog has nowhere real to send you.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-repo-view"}} = assigns) do
    assigns =
      assigns
      |> assign(:entries, @demo_repo_entries)
      |> assign(:contributors, @demo_repo_contributors)

    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Everything above, assembled: the owner trail from <code>breadcrumb/1</code>, the sections from <code>repo_tabs/1</code>, the tree from <code>file_table/1</code>, and the rail from <code>repo_about/1</code>. The frame
        itself is the only thing this component owns, which is why the three pieces arrive
        as slots — a surface that wants a commit list where the tree usually goes passes
        one, and no flag is added here.
      </p>
      <div class="-mx-6">
        <UI.repo_view
          owner="OpenAgentsInc"
          repo="openagents.com"
          owner_path={~p"/components/openagents-repo-view"}
        >
          <:tabs>
            <UI.repo_tabs>
              <:tab icon="code" href="#code" current>Code</:tab>
              <:tab icon="empty-circle" href="#issues" count={12}>Issues</:tab>
              <:tab icon="pull-request-open" href="#pulls" count={3}>Pull requests</:tab>
              <:tab icon="cube" href="#projects">Projects</:tab>
              <:tab icon="book-open" href="#wiki">Wiki</:tab>
              <:tab icon="chart" href="#insights">Insights</:tab>
              <:tab icon="settings-cog" href="#settings">Settings</:tab>
            </UI.repo_tabs>
          </:tabs>

          <UI.file_table
            owner="OpenAgentsInc"
            repo="openagents.com"
            ref="main"
            entries={@entries}
            branches={2}
            tags={0}
            commits={234}
          >
            <:actions>
              <UI.input
                id="demo-go-to-file"
                type="text"
                name="go-to-file"
                placeholder="Go to file"
                aria-label="Go to file"
                class="input file-table__search"
              />
              <UI.button size={:sm}>Add file</UI.button>
              <UI.button variant={:primary} size={:sm}>Code</UI.button>
            </:actions>
            <:commit>
              <UI.avatar size={:sm} fallback="A" label="AtlantisPleb" />
              <strong>AtlantisPleb</strong>
              <span>Group the agent's surfaces under her name</span>
              <code>86416fc</code>
              <span>15 minutes ago</span>
            </:commit>
          </UI.file_table>

          <:about>
            <UI.repo_about description="The Agent Forge" license="AGPL-3.0" contributors={2}>
              <:link icon="link" href="https://openagents.com">openagents.com</:link>
              <:link icon="book" navigate="/docs">Readme</:link>
              <:link icon="text" navigate="/changelog">Activity</:link>
              <:stat icon="star">2 stars</:stat>
              <:stat icon="eye">0 watching</:stat>
              <:stat icon="branch">0 forks</:stat>
              <:contributor :for={person <- @contributors} name={person.name} />
              <:language percent={91.8}>Elixir</:language>
              <:language percent={3.1}>CSS</:language>
              <:language percent={3.1}>Shell</:language>
              <:language percent={1.0}>JavaScript</:language>
              <:language percent={1.0}>Other</:language>
            </UI.repo_about>
          </:about>
        </UI.repo_view>
      </div>
      <p class="text-sm text-base-content/60">
        The tree, the commit subjects, the branch, the contributors, and the commit count
        are this repository's own — each row's message is what <code>git log -1 -- &lt;path&gt;</code>
        says about that path. A composed demo is only worth reading if the composition is
        carrying real proportions; invented ones make every column look comfortable.
      </p>
      <p class="text-sm text-base-content/60">
        The rail becomes a second column above 1024px and falls below the tree under it.
        Source order is already the narrow order, so nothing reorders: what a repository
        is, how it is licensed, and who wrote it are what a reader wants beside the file
        list on a desktop and after it on a phone.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "openagents-stack-map"}} = assigns) do
    assigns =
      assign(assigns, :layers, [
        %{
          title: "Add frontend",
          number: 32,
          branch: "frontend",
          state: "draft",
          href: "#pr-32"
        },
        %{
          title: "Add API endpoints",
          number: 30,
          branch: "api-endpoints",
          state: "open",
          href: "#pr-30"
        },
        %{
          title: "Add authentication layer",
          number: 24,
          branch: "auth-layer",
          state: "open",
          current: true
        }
      ])

    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A stacked pull request's place in its stack, at a glance. Layers arrive
        top-first and the trunk anchors the bottom, the way the branches actually
        chain. Each layer wears its pull request state as a coloured glyph, and the
        one the reader is viewing is washed and marked <code>aria-current="page"</code>
        rather than linked — a page linking to itself is a dead control that still
        looks live.
      </p>
      <div class="max-w-md">
        <UI.stack_map
          id="demo-stack-map"
          number={31}
          trunk="main"
          trunk_href="#main"
          add_href="#add"
          layers={@layers}
        >
          <:action>
            <UI.button variant={:ghost} size={:sm}>Unstack</UI.button>
          </:action>
        </UI.stack_map>
      </div>
      <p class="text-sm text-base-content/60">
        The connector rail threads through the state glyphs so the chain reads as one
        object, and the <strong>Add to stack</strong>
        row sits above the top layer because that is where the next layer would go. The
        header's action slot holds stack-level controls — here an unstack affordance.
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

      <p class="text-sm text-base-content/60">
        A muted run ahead of the headline, a command to run, a note qualifying it, and
        quiet links under everything else. Putting the quiet half first means the eye
        lands on the name rather than on the word announcing it.
      </p>
      <div class="demo-frame">
        <Landing.hero
          title="Coder."
          title_lead="Introducing"
          description="Your all-in-one coding agent."
        >
          <:eyebrow>
            <Landing.announce lead="Coder is here" detail="Install it in one command" href="#" />
          </:eyebrow>
          <:command>
            <Landing.install_command
              id="demo-hero-install-command"
              command={OpenAgentsWeb.CliInstall.unix()}
              windows_command={OpenAgentsWeb.CliInstall.windows()}
            />
          </:command>
          <:note>Every new account starts with $20 of credit.</:note>
          <:links>
            <UI.button href="#" variant={:ghost} size={:sm} class="hero__link">
              Read the docs <UI.icon name="chevron-right" />
            </UI.button>
            <UI.button href="#" variant={:ghost} size={:sm} class="hero__link">
              Changelog <UI.icon name="chevron-right" />
            </UI.button>
          </:links>
        </Landing.hero>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-announce"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Three registers on one line — a tag, the claim, a detail — because an
        announcement set at a single weight is indistinguishable from a caption. The tag
        carries the band's only accent, which is what makes the pill findable before it
        is read. Below 480px the detail drops rather than widening the pill past the
        screen.
      </p>
      <div class="demo-frame flex flex-wrap items-center justify-center gap-3">
        <Landing.announce lead="Coder is here" detail="Install it in one command" href="#" />
        <Landing.announce tag="Beta" lead="Computers" glyph={nil} href="#" />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "landing-install-command"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The whole frame is the control, not a button beside it: the command is there to
        be taken rather than read, and a small target next to a long piece of text asks
        the reader to aim at the smaller of the two. A command wider than the frame
        scrolls and fades out under the glyph instead of wrapping.
      </p>
      <div class="demo-frame flex justify-center">
        <Landing.install_command
          id="demo-install-command"
          command={OpenAgentsWeb.CliInstall.unix()}
          windows_command={OpenAgentsWeb.CliInstall.windows()}
        />
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
          <:feature>Agents on our computers</:feature>
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

  defp component_demo(%{item: %{slug: "pull-request-state"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A pull request on this forge is an issue row with a <code>pull_requests</code>
        record pointing at it, which is why the two share a number space. That made
        PR #119 and issue #114 read as duplicates of each other. This is the glyph that
        tells them apart, coloured off the same category ladder <code>issue_state/1</code>
        uses so both kinds stay in one palette.
      </p>
      <div class="flex flex-wrap gap-x-6 gap-y-3">
        <Circle.pull_request_state state="open" show_label />
        <Circle.pull_request_state state="draft" show_label />
        <Circle.pull_request_state state="merged" show_label />
        <Circle.pull_request_state state="closed" show_label />
      </div>
      <div class="flex flex-wrap gap-x-6 gap-y-3">
        <Circle.issue_state state="open" show_label />
        <Circle.pull_request_state state="open" show_label />
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

  # ── AI conversation ───────────────────────────────────────────────────────
  # Ported from Vercel's AI Elements. Each page composes a whole family the way
  # a caller composes it, and shows the states the family exists to keep apart:
  # a tool call has seven, and a demo of one of them documents nothing.

  defp component_demo(%{item: %{slug: "ai-conversation"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Two boxes: the outer one positions and clips, the inner one scrolls. That split is
        what lets the scroll control hold still at the bottom edge while the transcript
        moves behind it. A colocated hook keeps the viewport pinned while the reader is
        already at the bottom, and lets go the moment they scroll up.
      </p>
      <Conversation.conversation
        id="demo-conversation"
        class="h-72 rounded-lg border border-border"
      >
        <Conversation.conversation_content class="space-y-6 p-4">
          <Conversation.message from="system">
            <Conversation.message_content text="Run `scv.13` opened on `OpenAgentsInc/openagents.com`." />
          </Conversation.message>
          <Conversation.message from="user">
            <Conversation.message_content text="Why did scv-13 revert its own patch?" />
          </Conversation.message>
          <Conversation.message from="assistant">
            <Conversation.message_avatar name="Sarah" />
            <Conversation.message_content text="`targets_test.exs` stayed red after the third attempt, so the run hit the revert rule in `SELF-EDIT-001` and put the worktree back where it found it." />
          </Conversation.message>
          <Conversation.message from="user">
            <Conversation.message_content text="Show me the third attempt." />
          </Conversation.message>
          <Conversation.message from="assistant">
            <Conversation.message_avatar name="Sarah" />
            <Conversation.message_content
              text="Reading the transcript for attempt three"
              streaming
            />
          </Conversation.message>
        </Conversation.conversation_content>
      </Conversation.conversation>
      <p class="text-sm text-base-content/60">
        With nothing in it the same scroller carries a placeholder rather than an empty
        box, and the scroll control is left off, because there is nowhere to go.
      </p>
      <Conversation.conversation
        id="demo-conversation-empty"
        scroll_button={false}
        class="h-44 rounded-lg border border-border"
      >
        <Conversation.conversation_content class="grid h-full place-items-center p-4">
          <Conversation.conversation_empty_state
            icon="chat"
            title="No messages yet"
            description="Ask about a repository, or start an SCV run."
          />
        </Conversation.conversation_content>
      </Conversation.conversation>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-message"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A turn is a row of siblings the caller orders, not one component with a slot per
        position: an assistant turn wants a face, a body, and controls; a user turn wants
        only a body, and dropping a part should not mean passing an empty slot. The <code>from</code>
        attribute lands as the marker class every rule inside the body reads, which is
        what moves a user turn to the right and gives it a bubble.
      </p>
      <div class="space-y-6">
        <Conversation.message id="demo-message-user" from="user">
          <Conversation.message_content text="Which module decides whether an SCV run is admitted?" />
        </Conversation.message>

        <Conversation.message id="demo-message-assistant" from="assistant">
          <Conversation.message_avatar name="Sarah" />
          <Conversation.message_content text="`OpenAgents.Forge.Targets` scores the candidates and `Placement` admits one. The refusal path is the interesting half: an expired capability manifest is refused before scoring, so it never reaches the queue." />
          <Conversation.message_actions>
            <Conversation.message_action label="Copy">
              <UI.icon name="copy" class="size-4" />
            </Conversation.message_action>
            <Conversation.message_action label="Regenerate">
              <UI.icon name="regenerate" class="size-4" />
            </Conversation.message_action>
            <Conversation.message_action label="Good answer">
              <UI.icon name="thumb-up" class="size-4" />
            </Conversation.message_action>
            <Conversation.message_action label="Bad answer">
              <UI.icon name="thumb-down" class="size-4" />
            </Conversation.message_action>
          </Conversation.message_actions>
        </Conversation.message>

        <Conversation.message id="demo-message-streaming" from="assistant">
          <Conversation.message_avatar name="Sarah" />
          <Conversation.message_content
            text="Checking whether `Placement.admit/2` is still"
            streaming
          />
        </Conversation.message>

        <Conversation.message id="demo-message-system" from="system">
          <Conversation.message_content text="Budget window exhausted. The run resumes at the next window." />
        </Conversation.message>
      </div>
      <p class="text-sm text-base-content/60">
        The streaming turn is the one worth reading twice. Its text ends mid-sentence and
        still renders, because <code>streaming</code>
        tells the Markdown renderer to close what the model has not closed yet.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-shimmer"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A highlight travelling through the text rather than a spinner beside it: the words
        stay readable the whole time, so waiting says what it is waiting for. <code>spread</code>
        widens the band, which is how a long line and a short one can take the same time
        to sweep.
      </p>
      <div class="space-y-3">
        <Conversation.shimmer id="demo-shimmer-short" text="Thinking" />
        <Conversation.shimmer
          id="demo-shimmer-line"
          text="Reading lib/openagents/forge/targets.ex"
        />
        <Conversation.shimmer
          id="demo-shimmer-wide"
          text="Planning the change across four files"
          spread={4}
        />
        <Conversation.shimmer
          id="demo-shimmer-heading"
          text="Working"
          tag="h3"
          class="text-lg font-medium"
        />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-suggestions"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Openers a reader can send unedited. The row scrolls sideways rather than wrapping,
        because a wrapped set changes height as it changes length, and a control that
        moves the composer down the page every time the model finishes is worse than one
        the reader has to scroll.
      </p>
      <Conversation.suggestions id="demo-suggestions">
        <Conversation.suggestion suggestion="What changed in this repository today?" />
        <Conversation.suggestion suggestion="Why did the last SCV run refuse?" />
        <Conversation.suggestion suggestion="Open an issue for the flaky targets test" />
        <Conversation.suggestion suggestion="Summarise the staging deploy" variant={:secondary} />
        <Conversation.suggestion suggestion="Show me the diff" variant={:ghost} size={:xs} />
      </Conversation.suggestions>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-toolbar"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The bar that floats over a transcript. It takes a <code>label</code>
        because a bar of icon buttons with no name is a set of unexplained glyphs to
        anyone not looking at it.
      </p>
      <div class="relative h-40 rounded-lg border border-border bg-muted/30">
        <Conversation.toolbar id="demo-toolbar" label="Transcript actions">
          <Conversation.message_action label="Search this run">
            <UI.icon name="search" class="size-4" />
          </Conversation.message_action>
          <Conversation.message_action label="Export transcript">
            <UI.icon name="download" class="size-4" />
          </Conversation.message_action>
          <Conversation.message_action label="Share run">
            <UI.icon name="share" class="size-4" />
          </Conversation.message_action>
        </Conversation.toolbar>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-controls"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The same idea one level down: a group of actions that has to stay legible over
        whatever it sits on. Here it sits over the transcript ground rather than the page
        ground, which is the case the treatment exists for.
      </p>
      <div class="relative h-40 rounded-lg border border-border bg-muted/30 p-4">
        <Conversation.controls id="demo-controls" label="Run controls">
          <UI.button variant={:ghost} size={:sm}>
            <UI.icon name="pause" class="size-4" /> Pause
          </UI.button>
          <UI.button variant={:ghost} size={:sm}>
            <UI.icon name="stop" class="size-4" /> Stop
          </UI.button>
          <UI.button variant={:ghost} size={:sm}>
            <UI.icon name="arrow-rotate-cw" class="size-4" /> Retry
          </UI.button>
        </Conversation.controls>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-persona"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Upstream this is a WebGL canvas playing one of six remote animations. What
        survived the port is the contract: a fixed set of states, one presence marker, and
        a name. Two states borrow a marker rather than introduce a colour — <code>thinking</code>
        reads as running and <code>asleep</code>
        as ended — and the marker is decorative, because the word beside it already says
        it.
      </p>
      <div class="grid gap-4 sm:grid-cols-2">
        <Conversation.persona id="demo-persona-idle" name="Sarah" state="idle" />
        <Conversation.persona id="demo-persona-listening" name="Sarah" state="listening" />
        <Conversation.persona id="demo-persona-thinking" name="Sarah" state="thinking" />
        <Conversation.persona id="demo-persona-speaking" name="Sarah" state="speaking" />
        <Conversation.persona id="demo-persona-asleep" name="Sarah" state="asleep" />
        <Conversation.persona
          id="demo-persona-labelled"
          name="scv-13"
          state="thinking"
          status_label="Reverting the third attempt"
        />
      </div>
    </div>
    """
  end

  # ── AI reasoning ──────────────────────────────────────────────────────────

  defp component_demo(%{item: %{slug: "ai-reasoning"}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-base-content/60">
        A native <code>details</code>, so the disclosure needs no script and carries its
        own <code>aria-expanded</code>. The server writes the initial state, which keeps
        "open while it streams, closed once it lands" a LiveView decision: pass
        <code phx-no-curly-interpolation>open={@streaming}</code>
        and re-render. A reader who toggles it owns it until the next render of that
        attribute.
      </p>
      <Reasoning.reasoning id="demo-reasoning-open" open>
        <Reasoning.reasoning_trigger streaming />
        <Reasoning.reasoning_content
          text="The question is about admission, not scoring. `Targets` ranks candidates, but the refusal happens earlier"
          streaming
        />
      </Reasoning.reasoning>
      <Reasoning.reasoning id="demo-reasoning-closed">
        <Reasoning.reasoning_trigger duration={12} />
        <Reasoning.reasoning_content text="The question is about admission, not scoring. `Targets` ranks candidates, but the refusal happens earlier, in the capability check, so an expired manifest never reaches the queue." />
      </Reasoning.reasoning>
      <p class="text-sm text-base-content/60">
        Open above, closed below. The trigger says the same thing either way, and it is
        the only part that changes when the stream ends: the pulsing "Thinking…" becomes
        a duration.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-chain-of-thought"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Steps down a rail. <code>status</code>
        is the whole design: the step being worked reads at full strength, the ones behind
        it are muted, and the ones ahead are dimmed further, so the reader's eye lands on
        the present without an animation asking it to.
      </p>
      <Reasoning.chain_of_thought id="demo-cot" open>
        <Reasoning.chain_of_thought_header>
          Answering a question about this repository
        </Reasoning.chain_of_thought_header>
        <Reasoning.chain_of_thought_content>
          <Reasoning.chain_of_thought_step
            icon="search"
            label="Search for the admission path"
            description="Ranked by how often each file names a capability manifest."
            status={:complete}
          >
            <Reasoning.chain_of_thought_search_results>
              <Reasoning.chain_of_thought_search_result>
                lib/openagents/forge/targets.ex
              </Reasoning.chain_of_thought_search_result>
              <Reasoning.chain_of_thought_search_result>
                lib/openagents/cloud/placement.ex
              </Reasoning.chain_of_thought_search_result>
              <Reasoning.chain_of_thought_search_result>
                docs/cloud/INVARIANTS.md
              </Reasoning.chain_of_thought_search_result>
            </Reasoning.chain_of_thought_search_results>
          </Reasoning.chain_of_thought_step>
          <Reasoning.chain_of_thought_step
            icon="document"
            label="Read Placement.admit/2"
            description="The refusal is ahead of the scoring, not inside it."
            status={:complete}
          />
          <Reasoning.chain_of_thought_step
            icon="chart"
            label="Check the last twenty runs for the same refusal"
            status={:active}
          >
            <Reasoning.chain_of_thought_image caption="Refusals by reason, last twenty runs">
              <img src={~p"/images/logo.svg"} alt="" class="h-24 w-auto opacity-60" />
            </Reasoning.chain_of_thought_image>
          </Reasoning.chain_of_thought_step>
          <Reasoning.chain_of_thought_step
            icon="edit-pencil"
            label="Write the answer"
            status={:pending}
          />
        </Reasoning.chain_of_thought_content>
      </Reasoning.chain_of_thought>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-tool"}} = assigns) do
    assigns = assign(assigns, :tool_calls, @demo_tool_calls)

    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-base-content/60">
        Seven states, all of them here, because the badge is the taxonomy and one happy
        call documents none of it. Four describe a call's own progress — arguments still
        arriving, arguments complete, a result, a failure — and three describe a call that
        needed a person: waiting on approval, answered, and refused.
      </p>
      <Reasoning.tool :for={call <- @tool_calls} id={"demo-tool-#{call.state}"} open>
        <Reasoning.tool_header type={"tool-" <> call.name} tool_name={call.name} state={call.state} />
        <Reasoning.tool_content>
          <Reasoning.tool_input input={call.input} />
          <Reasoning.tool_output
            :if={call.output || call.error}
            output={call.output}
            error_text={call.error}
          />
        </Reasoning.tool_content>
      </Reasoning.tool>
      <p class="text-sm text-base-content/60">
        Arguments and results are preformatted text, not highlighted code: the code-block
        port is <.link
          patch={~p"/components/ai-code-block"}
          class="underline underline-offset-2 hover:no-underline"
        >a separate component</.link>, and claiming syntax highlighting that is not
        happening would be worse than plain text.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-task"}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-base-content/60">
        What one piece of work did, and which files it touched. Open by default, as
        upstream: a task is written into the transcript once it is finished, so the first
        thing a reader wants is its contents, not its title.
      </p>
      <Reasoning.task id="demo-task-open" open>
        <Reasoning.task_trigger title="Fixed the flaky targets test" />
        <Reasoning.task_content>
          <Reasoning.task_item>
            Read
            <Reasoning.task_item_file>
              test/openagents/forge/targets_test.exs
            </Reasoning.task_item_file>
          </Reasoning.task_item>
          <Reasoning.task_item>
            Found the ordering assumption in
            <Reasoning.task_item_file>lib/openagents/forge/targets.ex</Reasoning.task_item_file>
          </Reasoning.task_item>
          <Reasoning.task_item>
            Sorted the candidates by identifier before scoring
          </Reasoning.task_item>
          <Reasoning.task_item>
            Ran <code>mix test --seed 0</code>: 1416 passed, 14 excluded
          </Reasoning.task_item>
        </Reasoning.task_content>
      </Reasoning.task>
      <Reasoning.task id="demo-task-closed" open={false}>
        <Reasoning.task_trigger title="Checked the staging fleet before starting" />
        <Reasoning.task_content>
          <Reasoning.task_item>
            Read
            <Reasoning.task_item_file>infra/staging/outputs.tf</Reasoning.task_item_file>
          </Reasoning.task_item>
        </Reasoning.task_content>
      </Reasoning.task>
      <p class="text-sm text-base-content/60">
        The second one is closed, which is what a long run needs: everything the agent did
        stays in the transcript, and only the task under discussion stays open.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-plan"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The one part of this batch that takes slots rather than siblings. A <code>details</code>
        hides every child but its summary, and this footer has to stay visible while the
        body collapses — approving a plan you cannot see is the one thing to prevent — so
        the parent places the footer outside the collapsing region.
      </p>
      <Reasoning.plan id="demo-plan" open>
        <:header>
          <div>
            <Reasoning.plan_title>Make the targets test deterministic</Reasoning.plan_title>
            <Reasoning.plan_description>
              Four steps, two of them in files this run has already read.
            </Reasoning.plan_description>
          </div>
          <Reasoning.plan_trigger />
        </:header>
        <Reasoning.task id="demo-plan-step-1" open={false}>
          <Reasoning.task_trigger title="Sort candidates by identifier before scoring" />
          <Reasoning.task_content>
            <Reasoning.task_item>
              <Reasoning.task_item_file>lib/openagents/forge/targets.ex</Reasoning.task_item_file>
            </Reasoning.task_item>
          </Reasoning.task_content>
        </Reasoning.task>
        <Reasoning.task id="demo-plan-step-2" open={false}>
          <Reasoning.task_trigger title="Assert the order, not just the membership" />
          <Reasoning.task_content>
            <Reasoning.task_item>
              <Reasoning.task_item_file>
                test/openagents/forge/targets_test.exs
              </Reasoning.task_item_file>
            </Reasoning.task_item>
          </Reasoning.task_content>
        </Reasoning.task>
        <Reasoning.task id="demo-plan-step-3" open={false}>
          <Reasoning.task_trigger title="Run the suite at three seeds" />
          <Reasoning.task_content>
            <Reasoning.task_item>mix test --seed 0, --seed 1, --seed 2</Reasoning.task_item>
          </Reasoning.task_content>
        </Reasoning.task>
        <:footer>
          <Reasoning.plan_action>
            <UI.button variant={:primary} size={:sm}>Approve</UI.button>
          </Reasoning.plan_action>
          <Reasoning.plan_action>
            <UI.button variant={:outline} size={:sm}>Ask for changes</UI.button>
          </Reasoning.plan_action>
        </:footer>
      </Reasoning.plan>
      <p class="text-sm text-base-content/60">
        Collapse it with the control in its header. The two actions stay where they are.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-checkpoint"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A point the run can be returned to, drawn as a rule across the transcript so it
        reads as a division rather than another message. The rule fills whatever width the
        controls leave, which is why the label and the action can be any length.
      </p>
      <div class="space-y-4">
        <Reasoning.checkpoint id="demo-checkpoint-plain">
          <Reasoning.checkpoint_icon />
          <span class="px-2 text-xs">Before the rebase onto main</span>
        </Reasoning.checkpoint>
        <Reasoning.checkpoint id="demo-checkpoint-restore">
          <Reasoning.checkpoint_icon />
          <span class="px-2 text-xs">After attempt two</span>
          <Reasoning.checkpoint_trigger tooltip="Restore the worktree to this point">
            Restore
          </Reasoning.checkpoint_trigger>
        </Reasoning.checkpoint>
        <Reasoning.checkpoint id="demo-checkpoint-current">
          <Reasoning.checkpoint_icon name="saved-filled-xs" />
          <span class="px-2 text-xs text-foreground">Current</span>
        </Reasoning.checkpoint>
      </div>
      <p class="text-sm text-base-content/60">
        Upstream the restore control carries a Radix tooltip. There is no tooltip
        primitive here, so <code>tooltip</code>
        becomes the native <code>title</code>: same text, no script, still announced.
      </p>
    </div>
    """
  end

  # ── AI composer ───────────────────────────────────────────────────────────

  defp component_demo(%{item: %{slug: "ai-prompt-input"}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-base-content/60">
        A real Phoenix form around a real input group. The textarea is bound to a <code>Phoenix.HTML.FormField</code>, not to a loose string, so the composer submits
        the way every other form in this app does. Everything else — the growing height,
        Enter to submit, dropped and pasted files — is one colocated hook, because none of
        it can be expressed in markup.
      </p>
      <PromptInput.prompt_input
        id="demo-prompt-input"
        for={@composer_form}
        accept="image/*,text/*"
        phx-submit="save"
      >
        <:drop_overlay>Drop files to attach them</:drop_overlay>
        <PromptInput.prompt_input_body>
          <PromptInput.prompt_input_textarea
            field={@composer_form[:message]}
            placeholder="Ask about this repository, or start a run"
          />
        </PromptInput.prompt_input_body>
        <PromptInput.prompt_input_toolbar>
          <PromptInput.prompt_input_tools>
            <PromptInput.prompt_input_action_menu_trigger menu="demo-prompt-input-actions" />
            <PromptInput.prompt_input_button tooltip="Search the web">
              <UI.icon name="globe" class="size-4" />
            </PromptInput.prompt_input_button>
            <PromptInput.prompt_input_model_select
              name="composer[model]"
              value="claude-opus-5"
            >
              <PromptInput.prompt_input_model_select_item value="claude-opus-5" selected>
                Claude Opus 5
              </PromptInput.prompt_input_model_select_item>
              <PromptInput.prompt_input_model_select_item value="claude-sonnet-4">
                Claude Sonnet 4
              </PromptInput.prompt_input_model_select_item>
            </PromptInput.prompt_input_model_select>
          </PromptInput.prompt_input_tools>
          <PromptInput.prompt_input_submit id="demo-prompt-input-submit" status={:ready} />
        </PromptInput.prompt_input_toolbar>
      </PromptInput.prompt_input>
      <PromptInput.prompt_input_action_menu id="demo-prompt-input-actions">
        <PromptInput.prompt_input_action_menu_content>
          <PromptInput.prompt_input_action_add_attachments for="demo-prompt-input" />
          <PromptInput.prompt_input_action_add_screenshot />
        </PromptInput.prompt_input_action_menu_content>
      </PromptInput.prompt_input_action_menu>

      <p class="text-sm text-base-content/60">
        The submit control is four controls, not one control with four colours. Each
        status draws a different glyph and carries a different accessible name, and the
        streaming one is a stop button rather than a disabled send — which is the only
        state where the reader has something to do.
      </p>
      <div class="flex flex-wrap items-center gap-6">
        <div :for={status <- [:ready, :submitted, :streaming, :error]} class="space-y-2">
          <PromptInput.prompt_input_submit id={"demo-submit-#{status}"} status={status} />
          <p class="text-xs text-base-content/60">{status}</p>
        </div>
      </div>

      <p class="text-sm text-base-content/60">
        With a header and a footer, the same group carries staged attachments above the
        text and a note below it, and the input group grows rather than scrolling.
      </p>
      <PromptInput.prompt_input id="demo-prompt-input-full" for={@composer_form} phx-submit="save">
        <PromptInput.prompt_input_header>
          <PromptInput.attachments variant={:inline}>
            <PromptInput.attachment variant={:inline}>
              <PromptInput.attachment_preview
                variant={:inline}
                media_category={:source}
                filename="targets.ex"
              />
              <PromptInput.attachment_info variant={:inline} label="targets.ex" />
              <PromptInput.attachment_remove variant={:inline} label="Remove targets.ex" />
            </PromptInput.attachment>
          </PromptInput.attachments>
        </PromptInput.prompt_input_header>
        <PromptInput.prompt_input_body>
          <PromptInput.prompt_input_textarea
            id="demo-prompt-input-full-textarea"
            field={@composer_form[:message]}
          />
        </PromptInput.prompt_input_body>
        <PromptInput.prompt_input_footer>
          This run can read the repository. It cannot push.
        </PromptInput.prompt_input_footer>
        <PromptInput.prompt_input_toolbar>
          <PromptInput.prompt_input_tools>
            <PromptInput.speech_input
              id="demo-prompt-input-speech"
              transcript_event="demo_transcript"
            />
          </PromptInput.prompt_input_tools>
          <PromptInput.prompt_input_submit id="demo-prompt-input-full-submit" status={:streaming} />
        </PromptInput.prompt_input_toolbar>
      </PromptInput.prompt_input>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-prompt-input-action-menu"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Upstream this is a Radix dropdown. Here it is the native popover API: click out to
        dismiss,
        <UI.kbd>Esc</UI.kbd>
        to close, the trigger as the anchor, and no script. The two actions that ship with
        it are the two the composer always has — reach the file input, and capture the
        screen.
      </p>
      <div class="flex items-center gap-3">
        <PromptInput.prompt_input_action_menu_trigger menu="demo-action-menu" />
        <span class="text-sm text-base-content/60">Open the menu</span>
      </div>
      <PromptInput.prompt_input_action_menu id="demo-action-menu" label="Composer actions">
        <PromptInput.prompt_input_action_menu_content>
          <PromptInput.prompt_input_action_add_attachments for="demo-prompt-input" />
          <PromptInput.prompt_input_action_add_screenshot />
          <PromptInput.prompt_input_action_menu_item>
            <UI.icon name="folder" class="mr-2 size-4" /> Add a repository
          </PromptInput.prompt_input_action_menu_item>
        </PromptInput.prompt_input_action_menu_content>
      </PromptInput.prompt_input_action_menu>
      <p class="text-sm text-base-content/60">
        The attach action names the composer it belongs to rather than holding a reference
        to it, because the file input it clicks is rendered by that composer.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-prompt-input-model-select"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A real <code>select</code>, which is the point: the model is part of what the
        composer submits, so it should arrive in the same params as the text rather than
        in client state the server has to be told about. The trigger is styled down to the
        toolbar's height so it sits in the row rather than on it.
      </p>
      <div class="flex flex-wrap items-center gap-4">
        <PromptInput.prompt_input_model_select name="demo[model]" value="claude-opus-5">
          <PromptInput.prompt_input_model_select_item value="claude-opus-5" selected>
            Claude Opus 5
          </PromptInput.prompt_input_model_select_item>
          <PromptInput.prompt_input_model_select_item value="claude-sonnet-4">
            Claude Sonnet 4
          </PromptInput.prompt_input_model_select_item>
          <PromptInput.prompt_input_model_select_item value="claude-haiku-4">
            Claude Haiku 4
          </PromptInput.prompt_input_model_select_item>
        </PromptInput.prompt_input_model_select>

        <PromptInput.prompt_input_model_select
          id="demo-model-select-disabled"
          name="demo[locked_model]"
          value="claude-opus-5"
          label="Model, fixed by the run"
          disabled
        >
          <PromptInput.prompt_input_model_select_item value="claude-opus-5" selected>
            Claude Opus 5
          </PromptInput.prompt_input_model_select_item>
        </PromptInput.prompt_input_model_select>
      </div>
      <p class="text-sm text-base-content/60">
        The second one is fixed, which is what a resumed run needs: changing the model
        mid-run would make the transcript describe two different agents.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-attachments"}} = assigns) do
    ~H"""
    <div class="space-y-6">
      <p class="text-sm text-base-content/60">
        Three layouts for the same file. <code>:grid</code>
        is the thumbnail wall above the composer, <code>:inline</code>
        is the chip row that fits inside it, and <code>:list</code>
        is the full-width row a review surface wants. The preview falls back to the glyph
        for the file's category, which is how an audio file stays distinguishable from a
        document with no thumbnail to show.
      </p>

      <div class="space-y-2">
        <p class="text-xs uppercase tracking-wide text-base-content/60">Grid</p>
        <PromptInput.attachments id="demo-attachments-grid" variant={:grid}>
          <PromptInput.attachment variant={:grid}>
            <PromptInput.attachment_preview
              variant={:grid}
              media_category={:image}
              src={~p"/images/logo.svg"}
              filename="graph.svg"
            />
            <PromptInput.attachment_remove variant={:grid} label="Remove graph.svg" />
          </PromptInput.attachment>
          <PromptInput.attachment variant={:grid}>
            <PromptInput.attachment_preview
              variant={:grid}
              media_category={:document}
              filename="receipt.pdf"
            />
            <PromptInput.attachment_remove variant={:grid} label="Remove receipt.pdf" />
          </PromptInput.attachment>
          <PromptInput.attachment variant={:grid}>
            <PromptInput.attachment_preview
              variant={:grid}
              media_category={:audio}
              filename="standup.m4a"
            />
            <PromptInput.attachment_remove variant={:grid} label="Remove standup.m4a" />
          </PromptInput.attachment>
        </PromptInput.attachments>
      </div>

      <div class="space-y-2">
        <p class="text-xs uppercase tracking-wide text-base-content/60">Inline</p>
        <PromptInput.attachments id="demo-attachments-inline" variant={:inline}>
          <PromptInput.attachment variant={:inline}>
            <PromptInput.attachment_preview
              variant={:inline}
              media_category={:source}
              filename="targets.ex"
            />
            <PromptInput.attachment_info variant={:inline} label="targets.ex" />
            <PromptInput.attachment_remove variant={:inline} label="Remove targets.ex" />
          </PromptInput.attachment>
          <PromptInput.attachment variant={:inline}>
            <PromptInput.attachment_preview
              variant={:inline}
              media_category={:video}
              filename="repro.mp4"
            />
            <PromptInput.attachment_info variant={:inline} label="repro.mp4" />
            <PromptInput.attachment_remove variant={:inline} label="Remove repro.mp4" />
          </PromptInput.attachment>
        </PromptInput.attachments>
      </div>

      <div class="space-y-2">
        <p class="text-xs uppercase tracking-wide text-base-content/60">List</p>
        <PromptInput.attachments id="demo-attachments-list" variant={:list}>
          <PromptInput.attachment variant={:list}>
            <PromptInput.attachment_preview
              variant={:list}
              media_category={:source}
              filename="placement.ex"
            />
            <PromptInput.attachment_info
              variant={:list}
              label="lib/openagents/cloud/placement.ex"
              media_type="text/x-elixir"
            />
            <PromptInput.attachment_remove variant={:list} label="Remove placement.ex" />
          </PromptInput.attachment>
          <PromptInput.attachment variant={:list}>
            <PromptInput.attachment_preview
              variant={:list}
              media_category={:unknown}
              filename="fleet.tfstate"
            />
            <PromptInput.attachment_info
              variant={:list}
              label="infra/staging/fleet.tfstate"
              media_type="application/json"
            />
            <PromptInput.attachment_remove variant={:list} label="Remove fleet.tfstate" />
          </PromptInput.attachment>
        </PromptInput.attachments>
      </div>

      <div class="space-y-2">
        <p class="text-xs uppercase tracking-wide text-base-content/60">Empty</p>
        <PromptInput.attachment_empty id="demo-attachments-empty" />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-speech-input"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Push-to-talk. The hook detects the Web Speech API, falls back to <code>MediaRecorder</code>, and disables itself when neither exists — then publishes
        what it found on the wrapper, so the whole treatment, including the three
        staggered rings while recording, is CSS keyed off data attributes rather than a
        re-render.
      </p>
      <div class="flex flex-wrap items-center gap-8">
        <PromptInput.speech_input id="demo-speech" transcript_event="demo_transcript" />
        <PromptInput.speech_input
          id="demo-speech-disabled"
          transcript_event="demo_transcript"
          disabled
        />
      </div>
      <p class="text-sm text-base-content/60">
        Recognized text arrives as an ordinary LiveView event. Recorded audio cannot
        travel in one, so in the fallback the hook writes the blob onto a file input the
        caller names, and disables itself when there is no such input to write to.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-mic-selector"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A native <code>select</code>
        the browser fills in after mount, which is why it carries <code>phx-update="ignore"</code>: the device list is knowledge the client has and
        the server does not, and a re-render must not throw it away. Until permission is
        granted the list is the placeholder alone, which is honest — the browser refuses
        to name devices it has not been allowed to.
      </p>
      <div class="flex flex-wrap items-center gap-4">
        <PromptInput.mic_selector id="demo-mic-selector" name="demo[mic]" />
        <PromptInput.mic_selector id="demo-mic-selector-seeded" name="demo[seeded_mic]">
          <PromptInput.mic_selector_item value="default" selected>
            MacBook Pro Microphone
          </PromptInput.mic_selector_item>
          <PromptInput.mic_selector_item value="usb-1">
            Shure MV7 (14ed:1012)
          </PromptInput.mic_selector_item>
        </PromptInput.mic_selector>
      </div>
      <p class="text-sm text-base-content/60">
        The second one is seeded from the server so the shape is visible here. In use, the
        hook replaces whatever it finds.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-model-selector"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The composer's select is for two models. This is for thirty: a native popover
        holding a search field, grouped rows, and shortcuts. Filtering runs in the browser
        against text already on the page, so typing costs no round trip and an empty
        result has words rather than a blank panel.
      </p>
      <div class="flex items-center gap-3">
        <PromptInput.model_selector_trigger panel="demo-model-selector">
          <PromptInput.model_selector_logo src={~p"/images/logo.svg"} provider="OpenAgents" />
          <PromptInput.model_selector_name>Claude Opus 5</PromptInput.model_selector_name>
        </PromptInput.model_selector_trigger>
        <span class="text-sm text-base-content/60">Open, then type to filter</span>
      </div>
      <PromptInput.model_selector id="demo-model-selector" label="Select a model">
        <PromptInput.model_selector_input placeholder="Search models..." />
        <PromptInput.model_selector_list>
          <PromptInput.model_selector_group heading="Anthropic">
            <PromptInput.model_selector_item value="Claude Opus 5" selected>
              <PromptInput.model_selector_name>Claude Opus 5</PromptInput.model_selector_name>
              <PromptInput.model_selector_shortcut>⌘1</PromptInput.model_selector_shortcut>
            </PromptInput.model_selector_item>
            <PromptInput.model_selector_item value="Claude Sonnet 4">
              <PromptInput.model_selector_name>Claude Sonnet 4</PromptInput.model_selector_name>
              <PromptInput.model_selector_shortcut>⌘2</PromptInput.model_selector_shortcut>
            </PromptInput.model_selector_item>
            <PromptInput.model_selector_item value="Claude Haiku 4">
              <PromptInput.model_selector_name>Claude Haiku 4</PromptInput.model_selector_name>
            </PromptInput.model_selector_item>
          </PromptInput.model_selector_group>
          <PromptInput.model_selector_separator />
          <PromptInput.model_selector_group heading="On this fleet">
            <PromptInput.model_selector_item value="Psion 1B pretrained">
              <PromptInput.model_selector_name>Psion 1B</PromptInput.model_selector_name>
            </PromptInput.model_selector_item>
          </PromptInput.model_selector_group>
          <PromptInput.model_selector_empty />
        </PromptInput.model_selector_list>
      </PromptInput.model_selector>
      <div class="flex items-center gap-3">
        <span class="text-sm text-base-content/60">Several providers behind one row:</span>
        <PromptInput.model_selector_logo_group>
          <PromptInput.model_selector_logo src={~p"/images/logo.svg"} provider="OpenAgents" />
          <PromptInput.model_selector_logo src={~p"/images/logo.svg"} provider="Psionic" />
        </PromptInput.model_selector_logo_group>
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-queue"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Turns the reader has already written but not yet sent. Each section is a native <code>details</code>, so the chevron rotates off the element's own
        <code>open</code>
        attribute and the disclosure works before any JavaScript loads.
      </p>
      <PromptInput.queue id="demo-queue">
        <PromptInput.queue_section open>
          <PromptInput.queue_section_trigger>
            <PromptInput.queue_section_label label="queued" count={2}>
              <:icon><UI.icon name="clock" class="size-4" /></:icon>
            </PromptInput.queue_section_label>
          </PromptInput.queue_section_trigger>
          <PromptInput.queue_section_content>
            <PromptInput.queue_list>
              <PromptInput.queue_item>
                <PromptInput.queue_item_indicator />
                <PromptInput.queue_item_content>
                  Run the suite at three seeds and report the flaky ones
                  <PromptInput.queue_item_description>
                    Sends after the current turn
                  </PromptInput.queue_item_description>
                </PromptInput.queue_item_content>
                <PromptInput.queue_item_actions>
                  <PromptInput.queue_item_action label="Remove from the queue">
                    <UI.icon name="x" class="size-4" />
                  </PromptInput.queue_item_action>
                </PromptInput.queue_item_actions>
              </PromptInput.queue_item>
              <PromptInput.queue_item>
                <PromptInput.queue_item_indicator />
                <PromptInput.queue_item_content>
                  Open an issue for whatever stays red
                  <PromptInput.queue_item_attachment>
                    <PromptInput.queue_item_file>targets_test.exs</PromptInput.queue_item_file>
                    <PromptInput.queue_item_image src={~p"/images/logo.svg"} alt="" />
                  </PromptInput.queue_item_attachment>
                </PromptInput.queue_item_content>
              </PromptInput.queue_item>
            </PromptInput.queue_list>
          </PromptInput.queue_section_content>
        </PromptInput.queue_section>

        <PromptInput.queue_section open={false}>
          <PromptInput.queue_section_trigger>
            <PromptInput.queue_section_label label="sent" count={1}>
              <:icon><UI.icon name="check" class="size-4" /></:icon>
            </PromptInput.queue_section_label>
          </PromptInput.queue_section_trigger>
          <PromptInput.queue_section_content>
            <PromptInput.queue_list>
              <PromptInput.queue_item>
                <PromptInput.queue_item_indicator completed />
                <PromptInput.queue_item_content completed>
                  Which module decides whether an SCV run is admitted?
                </PromptInput.queue_item_content>
              </PromptInput.queue_item>
            </PromptInput.queue_list>
          </PromptInput.queue_section_content>
        </PromptInput.queue_section>
      </PromptInput.queue>

      <p class="text-sm text-base-content/60">With nothing waiting:</p>
      <PromptInput.queue id="demo-queue-empty">
        <PromptInput.queue_empty />
      </PromptInput.queue>
    </div>
    """
  end

  # ── AI evidence ───────────────────────────────────────────────────────────

  defp component_demo(%{item: %{slug: "ai-code-block"}} = assigns) do
    assigns = assign(assigns, :code, @demo_code)

    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-base-content/60">
        Chrome, line numbers, and a copy affordance, but no syntax highlighting: the
        source tokenizes with Shiki in the browser, which is a second rendering engine
        this page has not earned. The numbers come from a CSS counter, so selecting the
        block copies the code without them.
      </p>
      <Evidence.code_block
        id="demo-code-block"
        code={@code}
        language="elixir"
        filename="lib/openagents/cloud/placement.ex"
        show_line_numbers
      >
        <:actions>
          <UI.text_button>Open in the repository</UI.text_button>
        </:actions>
      </Evidence.code_block>
      <p class="text-sm text-base-content/60">
        Without a filename, a language, or actions, the header holds only the copy
        control, and the numbers can be left off for a fragment nobody is going to cite by
        line.
      </p>
      <Evidence.code_block id="demo-code-block-bare" code={@code} />
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-snippet"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        One command in a read-only field rather than in a paragraph, so a reader can
        select it, tab to it, and copy it without selecting the prose around it. The
        prefix is decorative: it says "this is a shell command" without becoming part of
        what gets copied.
      </p>
      <div class="space-y-3">
        <Evidence.snippet id="demo-snippet-shell" code="mix precommit" prefix="$" />
        <Evidence.snippet
          id="demo-snippet-long"
          code="git fetch openagents && git rebase openagents/main && git push openagents HEAD:main"
          prefix="$"
          label="Push to the forge"
        />
        <Evidence.snippet
          id="demo-snippet-plain"
          code="OPENAGENTS_RELEASE_VSN=0.3.0"
          copy={false}
          label="Environment variable"
        />
      </div>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-terminal"}} = assigns) do
    assigns = assign(assigns, :output, @demo_terminal_output)

    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-base-content/60">
        A fixed dark ground rather than a themed one, because terminal output means the
        colours the program chose, and repainting them by palette would make the same run
        look like two different runs. Escape sequences are not parsed: strip them before
        passing the output, or the reader sees them.
      </p>
      <Evidence.terminal
        id="demo-terminal-streaming"
        title="scv-13 — mix test"
        output={@output}
        status="Running"
        streaming
      >
        <:actions>
          <UI.text_button>Stop</UI.text_button>
        </:actions>
      </Evidence.terminal>
      <p class="text-sm text-base-content/60">
        Composed by hand instead, one line at a time, when the prompt matters as much as
        the output.
      </p>
      <Evidence.terminal id="demo-terminal-lines" title="scv-13 — worktree">
        <Evidence.terminal_line>git status --short</Evidence.terminal_line>
        <Evidence.terminal_line prompt=" ">M lib/openagents/forge/targets.ex</Evidence.terminal_line>
        <Evidence.terminal_line prompt=" ">
          M test/openagents/forge/targets_test.exs
        </Evidence.terminal_line>
        <Evidence.terminal_line>git stash list</Evidence.terminal_line>
      </Evidence.terminal>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-sources"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        The count comes first and the list only on request, which is the right default for
        something a reader checks rather than reads: they want to know an answer was
        grounded before they want to know in what. A native <code>details</code>, so it needs no script.
      </p>
      <Evidence.sources id="demo-sources" count={4}>
        <Evidence.source
          href="https://openagents.com/OpenAgentsInc/openagents.com"
          title="lib/openagents/cloud/placement.ex"
        />
        <Evidence.source
          href="https://openagents.com/OpenAgentsInc/openagents.com"
          title="docs/cloud/INVARIANTS.md"
        />
        <Evidence.source href="https://hexdocs.pm/phoenix_live_view" title="Phoenix.LiveView" />
        <Evidence.source href="https://openagents.com/OpenAgentsInc/openagents.com" />
      </Evidence.sources>
      <p class="text-sm text-base-content/60">
        The last one has no title, so it falls back to the address. A source that cannot
        be named is still a source, and hiding it would overstate how much of the answer
        is accounted for.
      </p>
      <Evidence.sources id="demo-sources-open" count={1} open>
        <Evidence.source
          href="https://openagents.com/OpenAgentsInc/openagents.com"
          title="AGENTS.md"
        />
      </Evidence.sources>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-inline-citation"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A hostname chip mid-sentence, so the reader can see what a claim rests on without
        leaving the line. The card opens on hover and on focus within, which is what makes
        it reachable from the keyboard; the source paginates its sources in a carousel,
        and they are simply listed here, because a citation is scoped to one claim and the
        count stays small.
      </p>
      <p class="max-w-[68ch] text-sm leading-relaxed">
        An expired capability manifest is refused before scoring <Evidence.inline_citation id="demo-citation">
          rather than ranked last
          <:source
            url="https://openagents.com/OpenAgentsInc/openagents.com/blob/main/docs/cloud/INVARIANTS.md"
            title="Cloud invariants"
            description="Admission checks capability freshness ahead of placement."
          />
          <:source
            url="https://openagents.com/OpenAgentsInc/openagents.com/blob/main/lib/openagents/cloud/placement.ex"
            title="Placement.admit/2"
          />
        </Evidence.inline_citation>, so it never reaches the queue at all.
      </p>
      <p class="max-w-[68ch] text-sm leading-relaxed">
        The quote treatment carries the sentence a source actually said: <Evidence.inline_citation id="demo-citation-quote">
          the refusal is a policy decision
          <:source url="https://openagents.com/OpenAgentsInc/openagents.com" title="AGENTS.md" />
        </Evidence.inline_citation>.
      </p>
      <Evidence.inline_citation_quote>
        Treat invariant changes as policy changes.
      </Evidence.inline_citation_quote>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-context"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        How much of the window a turn spent, said twice: as a percentage and as an arc, so
        the meter survives greyscale and a screen reader alike. The ring is a masked conic
        gradient rather than a drawn arc, because inline SVG is not allowed in a product
        surface here. Costs are attributes — there is no pricing table in this app, so a
        caller that knows the price passes it.
      </p>
      <div class="flex flex-wrap items-center gap-6">
        <Evidence.context
          id="demo-context"
          used_tokens={128_400}
          max_tokens={1_000_000}
          input_tokens={96_000}
          output_tokens={12_400}
          reasoning_tokens={14_000}
          cached_tokens={6_000}
          input_cost={0.29}
          output_cost={0.19}
          reasoning_cost={0.21}
          cached_cost={0.01}
          total_cost={0.70}
        />
        <Evidence.context id="demo-context-high" used_tokens={870_000} max_tokens={1_000_000} />
        <Evidence.context id="demo-context-over" used_tokens={1_120_000} max_tokens={1_000_000} />
      </div>
      <p class="text-sm text-base-content/60">
        The third one is over budget. A bar that silently pins at full hides the one state
        worth seeing, so it clamps its width, turns to the danger tone, and says so in an
        attribute a test can assert on.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-artifact"}} = assigns) do
    assigns = assign(assigns, :code, @demo_code)

    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        Something the model produced, framed so the actions that act on it sit beside its
        name rather than under its contents. The body is whatever the artifact is — a
        patch, a document, a chart — and scrolls on its own, so a long artifact does not
        push the rest of the turn off the page.
      </p>
      <Evidence.artifact
        id="demo-artifact"
        title="targets.ex"
        description="Sorts candidates by identifier before scoring"
        class="h-72"
      >
        <:actions>
          <Evidence.artifact_action icon="copy" label="Copy the patch" />
          <Evidence.artifact_action icon="download" label="Download the patch" />
          <Evidence.artifact_action
            icon="external-link"
            label="Open in the repository"
            tooltip="Open lib/openagents/forge/targets.ex"
          />
        </:actions>
        <Evidence.code_block id="demo-artifact-code" code={@code} language="elixir" copy={false} />
      </Evidence.artifact>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-confirmation"}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-base-content/60">
        An ask before a step that cannot be taken back, and — the part that matters — it
        keeps showing its answer afterwards. A confirmation that vanishes once decided
        leaves a transcript that cannot say who allowed what, which is exactly what a
        transcript is for.
      </p>
      <Evidence.confirmation
        id="demo-confirmation-requested"
        state={:requested}
        title="Push scv-13's branch to the forge and open a pull request?"
      >
        <:actions>
          <Evidence.confirmation_action variant={:primary}>Approve</Evidence.confirmation_action>
          <Evidence.confirmation_action variant={:outline}>Deny</Evidence.confirmation_action>
        </:actions>
      </Evidence.confirmation>
      <Evidence.confirmation
        id="demo-confirmation-approved"
        state={:approved}
        title="Push scv-13's branch to the forge and open a pull request?"
        reason="Approved by mason. The suite was green at three seeds."
      />
      <Evidence.confirmation
        id="demo-confirmation-denied"
        state={:denied}
        title="Force-push over the staging branch?"
        reason="Denied by mason. Another run owns that branch."
      />
      <p class="text-sm text-base-content/60">
        The decided ones carry no controls, because there is nothing left to decide, and
        the reason is where the transcript earns its keep.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-question"}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-base-content/60">
        Both halves matter. A model that can only offer choices asks the wrong question
        sooner or later, and one that only offers a text box makes the reader redo work it
        has already done. The choices are real radio and checkbox inputs styled as chips,
        so selection, keyboard behaviour, and submission are the browser's job.
      </p>
      <Evidence.question
        id="demo-question-single"
        prompt="Which branch should scv-13 work on?"
        description="The repository has three branches with recent commits."
        name="branch"
        selection_mode={:single}
        selected={["main"]}
        text_label="Something else?"
        placeholder="Name a branch"
        submit_label="Use this branch"
      >
        <:option value="main">main</:option>
        <:option value="codex/repository-cli-docs">codex/repository-cli-docs</:option>
        <:option value="feat/ai-elements-catalog">feat/ai-elements-catalog</:option>
      </Evidence.question>

      <Evidence.question
        id="demo-question-multiple"
        prompt="Which surfaces should the run touch?"
        name="surface"
        selection_mode={:multiple}
        selected={["catalog", "tests"]}
        text="Leave the CSS alone; another run owns it."
        submit_label="Start the run"
      >
        <:option value="catalog">Component catalog</:option>
        <:option value="demos">Demo pages</:option>
        <:option value="tests">Tests</:option>
        <:option value="css">Stylesheet</:option>
      </Evidence.question>

      <Evidence.question
        id="demo-question-answered"
        prompt="Which branch should scv-13 work on?"
        name="answered_branch"
        selected={["main"]}
        disabled
        submit_label="Answered"
      >
        <:option value="main">main</:option>
        <:option value="codex/repository-cli-docs">codex/repository-cli-docs</:option>
      </Evidence.question>
      <p class="text-sm text-base-content/60">
        The third one is answered and disabled, which is the state the source could not
        reach: its submit control disabled itself from React state, so here the server
        decides, and an answered question stays legible in the transcript.
      </p>
    </div>
    """
  end

  defp component_demo(%{item: %{slug: "ai-image"}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/60">
        A generated image cannot travel through Markdown here: the sanitizer's allowlist
        has no <code>img</code>
        in it, so an image written into a model's prose is dropped before it reaches the
        page. It arrives as attributes instead — either a source or the base64 and media
        type a model returns, which become a data URI.
      </p>
      <div class="flex flex-wrap items-start gap-6">
        <Evidence.image
          id="demo-image"
          src={~p"/images/logo.svg"}
          alt="The OpenAgents mark"
          class="max-w-48"
        />
        <Evidence.image
          id="demo-image-wide"
          src={~p"/images/og-card-default.png"}
          alt="The default social card for openagents.com"
          class="max-w-md"
        />
      </div>
      <p class="text-sm text-base-content/60">
        <code>alt</code>
        is required rather than defaulted. A generated image is exactly the case where
        nothing nearby says what it shows, so an empty alternative would make the whole
        message disappear for a reader who cannot see it.
      </p>
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
