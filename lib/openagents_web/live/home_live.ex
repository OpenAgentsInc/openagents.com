defmodule OpenAgentsWeb.HomeLive do
  @moduledoc """
  Two pages behind one route.

  Signed out, this is the landing page, composed from
  `OpenAgentsWeb.UI.Landing` so the homepage and the component library cannot
  drift apart.

  Signed in, a marketing pitch is the wrong thing to show: the visitor has
  already been sold, and what they want is the state of the work. The same
  route renders a dashboard -- repositories, open issues, projects, what the
  forum is discussing, and what shipped recently -- the way a code host's home
  does.

  The dashboard describes the viewer's work across every repository they can
  read, not one repository chosen for them, and it says so by reading through
  the same authorized reads `/issues` and `/projects` compose. Each panel
  carries its own counts, so no number on the page can be read as a total over
  a scope it does not cover.

  Everything on the dashboard is real and clickable. Where a panel has nothing
  to show it says so plainly rather than rendering a placeholder, because a
  dashboard whose emptiness is disguised is worse than one that admits it.

  The landing page is flush -- it owns the full main area and scrolls itself --
  because landing bands set their own vertical rhythm against the viewport and
  a wrapper's padding would fight it. The dashboard is an ordinary page.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Accounts
  alias OpenAgents.Changelog
  alias OpenAgents.Forum
  alias OpenAgents.Issues
  alias OpenAgents.Projects
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.UI.Landing

  @repo "openagents.com"
  @feed_limit 8
  @project_limit 6
  @post_limit 6
  @changelog_limit 5

  @impl true
  def mount(_params, _session, socket) do
    {:ok, if(socket.assigns[:current_user], do: assign_dashboard(socket), else: socket)}
  end

  # Loaded once at mount rather than per render: none of it changes within a
  # visit, and the dashboard should not re-query on every diff.
  #
  # Read across every repository the viewer can read, through the same
  # authorized reads `/issues` and `/projects` compose, so the homepage cannot
  # disagree with them. It used to pick one repository -- the first `ready`
  # entry of the visible list -- and scope every panel and every count to it,
  # which reported `Open 0 / Closed 0 / Projects 0` to an owner whose backlog
  # lived in the repository that happened to sort second.
  defp assign_dashboard(socket) do
    user = socket.assigns.current_user
    repositories = Repositories.list_visible_repositories(user)

    # One bounded page each, and each page carries its own unpaginated total,
    # so the numbers beside a panel cost an aggregate rather than a whole
    # collection loaded only to be measured.
    {issues, open_issue_count} = Issues.list_visible_issues_page(user, state: "open", page: 1)

    {projects, open_project_count} =
      Projects.list_visible_projects_page(user, state: "open", page: 1)

    socket
    |> assign(:open_issue_count, open_issue_count)
    |> assign(:closed_issue_count, Issues.count_visible_issues(user, state: "closed"))
    |> assign(:open_project_count, open_project_count)
    |> assign(:closed_project_count, Projects.count_visible_projects(user, state: "closed"))
    |> assign(:issues, Enum.take(issues, @feed_limit))
    |> assign(:projects, Enum.take(projects, @project_limit))
    |> assign(:any_repository?, repositories != [])
    # The forum reads through the same viewer-authorized scope `/forum`
    # composes, one row per topic, so the panel cannot name a board the board
    # list would not.
    |> assign(
      :posts,
      Forum.list_recent_posts(operator?: Accounts.admin?(user), limit: @post_limit)
    )
    |> assign(:changelog, changelog_entries())
    |> stream(:repositories, repositories)
  end

  # The ledger is a bounded public projection and can legitimately refuse. An
  # empty rail is the honest answer; the home page should not crash over it.
  #
  # Its agent-layer rows carry no authored note, which is what left the rail
  # rendering a column of bare relative times. A row states what it is or it
  # does not render.
  defp changelog_entries do
    case Changelog.timeline(@repo) do
      {:ok, rows} ->
        rows
        |> Enum.map(&%{entry_at: &1.entry_at, summary: changelog_summary(&1)})
        |> Enum.reject(&is_nil(&1.summary))
        |> Enum.take(@changelog_limit)

      {:error, _reason} ->
        []
    end
  end

  defp changelog_summary(%{summary: summary}) when is_binary(summary) do
    case String.trim(summary) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp changelog_summary(%{short_sha: short_sha}) when is_binary(short_sha),
    do: "Receipted deploy of #{short_sha}"

  defp changelog_summary(_row), do: nil

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
              <%!-- Points at the workspace-wide list, not at one repository.
              A "view all" under a panel has to widen the set the panel shows,
              and a repository-scoped link under a cross-repository feed would
              narrow it instead. Per-repository entry points stay one row away
              in the Repositories panel. --%>
              <.link navigate={~p"/issues"} class="panel__more">
                View all <.icon name="arrow-right" />
              </.link>
            </header>

            <%!-- Beside the issues they count, rather than in the rail, where
            two integers with no panel attached read as a total over
            everything. --%>
            <dl class="stat-pairs" id="dashboard-issue-counts">
              <div>
                <dt>Open</dt>
                <dd id="dashboard-open-issue-count">{@open_issue_count}</dd>
              </div>
              <div>
                <dt>Closed</dt>
                <dd id="dashboard-closed-issue-count">{@closed_issue_count}</dd>
              </div>
            </dl>

            <ul :if={@issues != []} class="issue-feed">
              <li :for={issue <- @issues} class="issue-feed__row">
                <.icon name="circle-dashed" class="issue-feed__state" />
                <div class="issue-feed__body">
                  <.link
                    navigate={
                      ~p"/#{issue.repository.owner}/#{issue.repository.name}/issues/#{issue.number}"
                    }
                    class="issue-feed__title"
                  >
                    {issue.title}
                  </.link>
                  <p class="issue-feed__meta">
                    {issue.repository.owner}/{issue.repository.name} #{issue.number} opened {relative_time(
                      issue.inserted_at
                    )}
                  </p>
                </div>
                <span :if={issue.comments > 0} class="issue-feed__comments">
                  <.icon name="chat" /> {issue.comments}
                </span>
              </li>
            </ul>

            <p :if={@issues == [] and @any_repository?} class="panel__empty">
              No open issues in the repositories you can read.
            </p>
            <p :if={not @any_repository?} class="panel__empty">
              Import your first repository to start tracking issues.
            </p>
          </section>

          <section class="panel" aria-labelledby="dashboard-projects">
            <header class="panel__header">
              <h2 id="dashboard-projects" class="panel__title">Projects</h2>
              <.link navigate={~p"/projects"} class="panel__more">
                View all <.icon name="arrow-right" />
              </.link>
            </header>

            <dl class="stat-pairs" id="dashboard-project-counts">
              <div>
                <dt>Open</dt>
                <dd id="dashboard-open-project-count">{@open_project_count}</dd>
              </div>
              <div>
                <dt>Closed</dt>
                <dd id="dashboard-closed-project-count">{@closed_project_count}</dd>
              </div>
            </dl>

            <ul :if={@projects != []} class="project-list">
              <li :for={project <- @projects}>
                <.link
                  navigate={
                    ~p"/#{project.repository.owner}/#{project.repository.name}/projects/#{project.number}"
                  }
                  class="project-list__row"
                >
                  <.icon name="grid" />
                  <span class="project-list__title">{project.title}</span>
                  <span class="project-list__repository">
                    {project.repository.owner}/{project.repository.name}
                  </span>
                  <span class="project-list__state" data-state={project.state}>
                    {project.state}
                  </span>
                </.link>
              </li>
            </ul>

            <p :if={@projects == [] and @any_repository?} class="panel__empty">
              No open projects in the repositories you can read.
            </p>
            <p :if={not @any_repository?} class="panel__empty">
              Projects appear after you import a repository.
            </p>
          </section>
        </div>

        <aside class="dashboard__rail">
          <section class="panel" aria-labelledby="dashboard-repositories">
            <header class="panel__header">
              <h2 id="dashboard-repositories" class="panel__title">Repositories</h2>
              <.link navigate={~p"/repositories"} class="panel__more">
                View all <.icon name="arrow-right" />
              </.link>
            </header>

            <div id="dashboard-repository-list" phx-update="stream" class="space-y-2">
              <%!-- Carries an id because every child of a stream container
              needs one, including the one that is not a stream item. --%>
              <p id="dashboard-no-repositories" class="panel__empty hidden only:block">
                No repositories yet.
              </p>
              <.link
                :for={{id, repository} <- @streams.repositories}
                id={id}
                navigate={~p"/#{repository.namespace.slug}/#{repository.name}"}
                class="repo-card"
              >
                <.icon name="folder" />
                <span class="repo-card__name">
                  {repository.namespace.slug}/{repository.name}
                </span>
                <.badge variant={if(repository.lifecycle_state == "ready", do: :success, else: :info)}>
                  {repository.lifecycle_state}
                </.badge>
              </.link>
            </div>
          </section>

          <%!-- The one surface here where other people speak. It reads
          through the forum's own authorized read, shows the newest post of
          each recently active topic rather than several from one thread, and
          points at `/forum` -- the destination that widens the set -- rather
          than at whichever board happens to be busiest. --%>
          <section class="panel" aria-labelledby="dashboard-forum">
            <header class="panel__header">
              <h2 id="dashboard-forum" class="panel__title">Recent posts</h2>
              <.link navigate={~p"/forum"} class="panel__more">
                View all <.icon name="arrow-right" />
              </.link>
            </header>

            <ul :if={@posts != []} id="dashboard-post-list" class="post-rail">
              <li :for={post <- @posts} id={"dashboard-post-#{post.id}"} class="post-rail__row">
                <.link navigate={~p"/forum/t/#{post.topic_id}"} class="post-rail__title">
                  {post.topic.title}
                </.link>
                <%!-- The name the post was written under, which is what the
                thread shows. A migrated post keeps its legacy name until an
                identity claim resolves it, and the dashboard must not
                attribute it to an account the forum would not. --%>
                <p class="post-rail__meta">
                  {post.actor_display_name} in {post.topic.forum.title} · {relative_time(
                    post.created_at
                  )}
                </p>
              </li>
            </ul>

            <p :if={@posts == []} class="panel__empty">
              No posts yet on the boards you can read.
            </p>
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
            <.github_login id="home-cta-signin" size={:lg} />
            <%!-- Quieter than the action beside it. `variant` defaults to
            `:primary`, so two filled buttons sat side by side stating that
            both were the thing to do, which leaves a reader picking rather
            than proceeding. --%>
            <.button navigate={~p"/docs"} variant={:secondary} size={:lg}>
              Read the docs
            </.button>
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
            <.link navigate={~p"/docs/issues"}>Issues</.link>
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
