defmodule OpenAgentsWeb.HomeLive do
  @moduledoc """
  Two pages behind one route.

  Signed out, this is the landing page, composed from
  `OpenAgentsWeb.UI.Landing` so the homepage and the component library cannot
  drift apart.

  Signed in, a marketing pitch is the wrong thing to show: the visitor has
  already been sold, and what they want is the state of the work. The same
  route renders a dashboard -- repositories, open issues, projects, and what
  shipped recently -- the way a code host's home does.

  Everything on the dashboard is real and clickable. Where a panel has nothing
  to show it says so plainly rather than rendering a placeholder, because a
  dashboard whose emptiness is disguised is worse than one that admits it.

  The landing page is flush -- it owns the full main area and scrolls itself --
  because landing bands set their own vertical rhythm against the viewport and
  a wrapper's padding would fight it. The dashboard is an ordinary page.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Changelog
  alias OpenAgents.Issues
  alias OpenAgents.Projects
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.UI.Landing

  @repo "openagents.com"
  @feed_limit 8
  @changelog_limit 5

  @impl true
  def mount(_params, _session, socket) do
    {:ok, if(socket.assigns[:current_user], do: assign_dashboard(socket), else: socket)}
  end

  # Loaded once at mount rather than per render: none of it changes within a
  # visit, and the dashboard should not re-query on every diff.
  defp assign_dashboard(socket) do
    repository = Repositories.initial_repository!()
    {owner, name} = Repositories.initial_path()

    open_issues = Issues.list_issues(repository, state: "open")
    closed_issues = Issues.list_issues(repository, state: "closed")
    projects = Projects.list_projects(repository)

    socket
    |> assign(:owner, owner)
    |> assign(:name, name)
    |> assign(:open_count, length(open_issues))
    |> assign(:closed_count, length(closed_issues))
    |> assign(:project_count, length(projects))
    |> assign(:issues, Enum.take(open_issues, @feed_limit))
    |> assign(:projects, Enum.take(projects, 6))
    |> assign(:changelog, changelog_entries())
  end

  # The ledger is a bounded public projection and can legitimately refuse. An
  # empty rail is the honest answer; the home page should not crash over it.
  defp changelog_entries do
    case Changelog.timeline(@repo) do
      {:ok, rows} -> Enum.take(rows, @changelog_limit)
      {:error, _reason} -> []
    end
  end

  @impl true
  def render(%{current_user: user} = assigns) when not is_nil(user) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Home"
      wide
    >
      <div class="dashboard">
        <div class="dashboard__main">
          <section class="panel" aria-labelledby="dashboard-issues">
            <header class="panel__header">
              <h2 id="dashboard-issues" class="panel__title">Open issues</h2>
              <.link navigate={~p"/#{@owner}/#{@name}/issues"} class="panel__more">
                View all <.icon name="arrow-right" />
              </.link>
            </header>

            <ul :if={@issues != []} class="issue-feed">
              <li :for={issue <- @issues} class="issue-feed__row">
                <.icon name="circle-dashed" class="issue-feed__state" />
                <div class="issue-feed__body">
                  <.link
                    navigate={~p"/#{@owner}/#{@name}/issues/#{issue.number}"}
                    class="issue-feed__title"
                  >
                    {issue.title}
                  </.link>
                  <p class="issue-feed__meta">
                    #{issue.number} opened {relative_time(issue.inserted_at)}
                  </p>
                </div>
                <span :if={issue.comments > 0} class="issue-feed__comments">
                  <.icon name="chat" /> {issue.comments}
                </span>
              </li>
            </ul>

            <p :if={@issues == []} class="panel__empty">
              No open issues. <.link navigate={~p"/#{@owner}/#{@name}/issues/new"}>Open one</.link>.
            </p>
          </section>

          <section class="panel" aria-labelledby="dashboard-projects">
            <header class="panel__header">
              <h2 id="dashboard-projects" class="panel__title">Projects</h2>
              <.link navigate={~p"/#{@owner}/#{@name}/projects"} class="panel__more">
                View all <.icon name="arrow-right" />
              </.link>
            </header>

            <ul :if={@projects != []} class="project-list">
              <li :for={project <- @projects}>
                <.link
                  navigate={~p"/#{@owner}/#{@name}/projects/#{project.number}"}
                  class="project-list__row"
                >
                  <.icon name="grid" />
                  <span class="project-list__title">{project.title}</span>
                  <span class="project-list__state" data-state={project.state}>
                    {project.state}
                  </span>
                </.link>
              </li>
            </ul>

            <p :if={@projects == []} class="panel__empty">No projects yet.</p>
          </section>
        </div>

        <aside class="dashboard__rail">
          <section class="panel" aria-labelledby="dashboard-repo">
            <header class="panel__header">
              <h2 id="dashboard-repo" class="panel__title">Repository</h2>
            </header>

            <%!-- The code browser's owner segment is a literal in the router
            (a wildcard first segment would shadow every two-segment path), so
            the route is written the way the router declares it. --%>
            <.link navigate={~p"/OpenAgentsInc/#{@name}"} class="repo-card">
              <.icon name="folder" />
              <span class="repo-card__name">{@owner}/{@name}</span>
            </.link>

            <dl class="stat-pairs">
              <div>
                <dt>Open</dt>
                <dd>{@open_count}</dd>
              </div>
              <div>
                <dt>Closed</dt>
                <dd>{@closed_count}</dd>
              </div>
              <div>
                <dt>Projects</dt>
                <dd>{@project_count}</dd>
              </div>
            </dl>
          </section>

          <section class="panel" aria-labelledby="dashboard-changelog">
            <header class="panel__header">
              <h2 id="dashboard-changelog" class="panel__title">Latest from the changelog</h2>
            </header>

            <ol :if={@changelog != []} class="changelog-rail">
              <li :for={entry <- @changelog}>
                <p class="changelog-rail__when">{relative_time(entry.entry_at)}</p>
                <p class="changelog-rail__summary">{entry.summary}</p>
              </li>
            </ol>

            <p :if={@changelog == []} class="panel__empty">Nothing recorded yet.</p>

            <.link navigate={~p"/changelog"} class="panel__more">
              View changelog <.icon name="arrow-right" />
            </.link>
          </section>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      flush
    >
      <div class="landing-page">
        <Landing.layout_lines />

        <Landing.hero
          title="The Agent Forge"
          description="Purpose-built for planning and shipping issues. Designed for the agent era."
        >
          <:actions>
            <%= if @current_user do %>
              <.button
                id="home-cta-create"
                navigate={~p"/OpenAgentsInc/openagents.com/issues/new"}
                variant={:primary}
                size={:lg}
              >
                Create new issue
              </.button>
              <.button
                id="home-cta-browse"
                navigate={~p"/OpenAgentsInc/openagents.com/issues"}
                variant={:secondary}
                size={:lg}
              >
                View issues
              </.button>
            <% else %>
              <.github_login id="home-cta-signin" size={:lg} />
              <%!-- Quieter than the action beside it. `variant` defaults to
              `:primary`, so two filled buttons sat side by side stating that
              both were the thing to do, which leaves a reader picking rather
              than proceeding. --%>
              <.button navigate={~p"/docs"} variant={:secondary} size={:lg}>
                Read the docs
              </.button>
            <% end %>
          </:actions>

          <%!-- Commented out rather than deleted: the frame is right, what goes
          in it is not. An empty browser chrome captioned with the domain shows
          a reader nothing about the product and reads as a placeholder that
          was forgotten. Restore this when there is a real surface to put in
          it -- a screenshot, or a live view of the application.

          <:figure>
            <Landing.mockup>
              <div class="landing-figure">
                <div class="landing-figure__bar">
                  <span></span><span></span><span></span>
                </div>
                <p class="landing-figure__caption">openagents.com</p>
              </div>
            </Landing.mockup>
          </:figure>
          --%>
        </Landing.hero>

        <Landing.feature_grid title="Everything the work needs. Nothing it doesn't.">
          <:item title="Issues" icon="file-document">
            Plan, assign, label and close, over an API shaped after the one you already
            use.
          </:item>
          <:item title="Projects" icon="grid">
            Group issues into work that has a beginning and an end.
          </:item>
          <:item title="Milestones" icon="flag">
            Dates and scope, stated where the work is rather than in another tool.
          </:item>
          <:item title="Code" icon="code">
            Browse repositories and commits beside the issues that changed them.
          </:item>
          <:item title="Agents" icon="bolt">
            Durable workers that pick up an issue and see it through.
          </:item>
          <:item title="Receipts" icon="check-circle">
            Every run leaves evidence that can be read afterwards.
          </:item>
          <:item title="Changelog" icon="text">
            What shipped, generated from what actually shipped.
          </:item>
          <:item title="Status" icon="info">
            The system's own account of whether it is working.
          </:item>
        </Landing.feature_grid>

        <Landing.faq title="Questions">
          <:item question="Is this the whole application?" open>
            <p>
              Yes. The repository is AGPL-3.0, and every surface on this site is built
              from the same component system documented in the component library.
            </p>
          </:item>
          <:item question="Does it work without JavaScript?">
            <p>
              The marketing and documentation surfaces do. Menus are native popovers and
              disclosures are native <code>&lt;details&gt;</code> elements, so navigation
              works before any bundle has loaded.
            </p>
          </:item>
          <:item question="What does the API look like?">
            <p>
              It is shaped after GitHub's REST API and served under <code>/api/v3</code>. An existing client usually needs only a base URL
              change.
            </p>
          </:item>
        </Landing.faq>

        <Landing.cta
          title="Start shipping."
          description="Open an issue and let an agent pick it up."
        >
          <:actions>
            <.button navigate={~p"/docs"} variant={:primary} size={:lg}>
              Read the docs
            </.button>
          </:actions>
        </Landing.cta>

        <Landing.landing_footer
          tagline="Purpose-built for planning and shipping issues."
          copyright="© 2026 OpenAgents, Inc."
          note="AGPL-3.0. Every surface here is in the repository."
        >
          <:column title="Product">
            <.link navigate={~p"/docs"}>Documentation</.link>
            <.link navigate={~p"/OpenAgentsInc/openagents.com/issues"}>Issues</.link>
          </:column>
          <:column title="Transparency">
            <.link navigate={~p"/changelog"}>Changelog</.link>
            <.link navigate={~p"/status"}>Status</.link>
            <.link navigate={~p"/leaderboard"}>Leaderboard</.link>
          </:column>
          <:column title="API">
            <.link navigate={~p"/docs/rest-api"}>REST API</.link>
            <.link navigate={~p"/docs/status-api"}>Status API</.link>
          </:column>
        </Landing.landing_footer>
      </div>
    </Layouts.app>
    """
  end

  # Coarse on purpose. A dashboard wants "roughly when"; a precise timestamp
  # there invites the reader to do arithmetic they did not want to do.
  defp relative_time(nil), do: "recently"

  defp relative_time(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      s when s < 60 -> "just now"
      s when s < 3_600 -> "#{div(s, 60)}m ago"
      s when s < 86_400 -> "#{div(s, 3_600)}h ago"
      s when s < 2_592_000 -> "#{div(s, 86_400)}d ago"
      s -> "#{div(s, 2_592_000)}mo ago"
    end
  end

  defp relative_time(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> relative_time()
end
