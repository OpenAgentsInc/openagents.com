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

  It is also current. Every panel names a publisher and re-reads when it hears
  one, so an issue opened in another tab moves the count and the feed without a
  refresh, and the same holds for a project, a repository, a forum post, and a
  changelog entry. The announcements carry ids and nothing else: each panel
  re-reads through the same authorized read that filled it at mount, so a
  viewer can never be handed a row -- or a row counted into a number -- the
  database would have refused them. Bursts collapse into one re-read of only
  the panels that moved.

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
  alias OpenAgentsWeb.LiveRefresh
  alias OpenAgentsWeb.UI.Landing

  @repo "openagents.com"

  # The one line the landing page asks a reader to run. It is the command
  # `priv/docs/install-cli.md` documents and the script
  # `priv/static/install.sh` serves, so the page cannot advertise an installer
  # this site does not hand out.
  @install_command "curl -fsSL https://openagents.com/install.sh | sh"

  @feed_limit 8
  @project_limit 6
  @post_limit 6
  @changelog_limit 5

  @impl true
  def mount(params, _session, socket) do
    if socket.assigns[:current_user] do
      if connected?(socket), do: subscribe()

      {:ok,
       socket
       |> LiveRefresh.init()
       |> assign(:changed_repositories, MapSet.new())
       |> assign_dashboard()}
    else
      {:ok,
       socket
       |> assign(:device_user_code, device_user_code(params))
       |> assign(:install_command, @install_command)}
    end
  end

  # A reader who arrives here from `/device` was sent by their terminal, not by
  # a link to a product. `OpenAgentsWeb.UserAuth` puts the terminal's code in
  # the URL on the way past so this page can say what the sign-in is for; the
  # session it also wrote is what actually returns them afterwards, so this
  # value decides what is rendered and nothing else.
  #
  # It is cast rather than read. The parameter is printed on the page, so
  # admitting only the shape this application mints is what keeps a crafted
  # link from putting its own words in OpenAgents's mouth.
  defp device_user_code(params) when is_map(params) do
    case OpenAgents.DeviceAuthorizations.cast_user_code(params["user_code"]) do
      {:ok, code} -> code
      :error -> nil
    end
  end

  defp device_user_code(_not_mounted_at_router), do: nil

  # Every panel here already had a publisher or has one now, so the dashboard
  # can stop being a snapshot of the moment it was opened. The messages carry
  # ids and nothing else: each panel re-reads through the same authorized read
  # that filled it at mount, so a viewer can never be handed a row -- or a row
  # counted into a number -- that they could not have loaded themselves.
  defp subscribe do
    :ok = Repositories.subscribe_all_issues()
    :ok = Repositories.subscribe_all_projects()
    :ok = Repositories.subscribe_repository_changes()
    :ok = Forum.subscribe_posts()
    :ok = Changelog.subscribe()
  end

  @impl true
  def handle_info({:issues_changed, _repository_id}, socket),
    do: {:noreply, mark_stale(socket, :issues)}

  def handle_info({:projects_changed, _repository_id}, socket),
    do: {:noreply, mark_stale(socket, :projects)}

  def handle_info({:forum_posts_changed, _topic_id}, socket),
    do: {:noreply, mark_stale(socket, :posts)}

  def handle_info({:repository_changed, repository_id}, socket) do
    {:noreply,
     socket
     |> update(:changed_repositories, &MapSet.put(&1, repository_id))
     |> mark_stale(:repositories)}
  end

  def handle_info(:live_refresh, socket),
    do: {:noreply, LiveRefresh.run(socket, &refresh_panel/2)}

  def handle_info(message, socket) do
    if Changelog.ledger_event?(message),
      do: {:noreply, mark_stale(socket, :changelog)},
      else: {:noreply, socket}
  end

  # One re-armed timer, shared with every other live surface through
  # `LiveRefresh`, so a burst of announcements costs one re-read rather than
  # one repaint per event. Which panels re-read is remembered beside it, so an
  # issue burst never reloads the forum, the projects, or the ledger.
  defp mark_stale(socket, panel), do: LiveRefresh.mark_stale(socket, panel, &refresh_panel/2)

  defp refresh_panel(socket, :issues), do: assign_issues(socket)
  defp refresh_panel(socket, :projects), do: assign_projects(socket)
  defp refresh_panel(socket, :posts), do: assign_posts(socket)
  defp refresh_panel(socket, :changelog), do: assign_changelog(socket, refresh: true)

  defp refresh_panel(socket, :repositories) do
    socket.assigns.changed_repositories
    |> Enum.reduce(socket, &refresh_repository_row/2)
    |> assign(:changed_repositories, MapSet.new())
    |> assign(:any_repository?, Repositories.any_visible_repository?(socket.assigns.current_user))
  end

  # One row, re-read through this viewer's own visibility predicate, rather
  # than the whole collection: a repository announces itself on every accepted
  # push, and a rail that reloaded every repository it can read per push would
  # be the expensive half of the defect this fixes. A repository that has
  # stopped being readable -- deleted, or a membership revoked -- reads as
  # `nil` and leaves the rail.
  defp refresh_repository_row(repository_id, socket) do
    case Repositories.get_visible_repository(repository_id, socket.assigns.current_user) do
      nil -> stream_delete_by_dom_id(socket, :repositories, "repositories-#{repository_id}")
      repository -> stream_insert(socket, :repositories, repository)
    end
  end

  # Read once at mount and again whenever something says the panel moved.
  #
  # Read across every repository the viewer can read, through the same
  # authorized reads `/issues` and `/projects` compose, so the homepage cannot
  # disagree with them. It used to pick one repository -- the first `ready`
  # entry of the visible list -- and scope every panel and every count to it,
  # which reported `Open 0 / Closed 0 / Projects 0` to an owner whose backlog
  # lived in the repository that happened to sort second.
  defp assign_dashboard(socket) do
    socket
    |> assign_issues()
    |> assign_projects()
    |> assign_posts()
    |> assign_changelog()
    |> assign_repositories()
  end

  # One bounded page, and the page carries its own unpaginated total, so the
  # numbers beside a panel cost an aggregate rather than a whole collection
  # loaded only to be measured. That is as true of a live update as of a mount:
  # a refresh that counted by loading would reintroduce the read `93c3383`
  # removed, once per event instead of once per visit.
  defp assign_issues(socket) do
    user = socket.assigns.current_user
    {issues, open_issue_count} = Issues.list_visible_issues_page(user, state: "open", page: 1)

    socket
    |> assign(:open_issue_count, open_issue_count)
    |> assign(:closed_issue_count, Issues.count_visible_issues(user, state: "closed"))
    |> assign(:issues, Enum.take(issues, @feed_limit))
  end

  defp assign_projects(socket) do
    user = socket.assigns.current_user

    {projects, open_project_count} =
      Projects.list_visible_projects_page(user, state: "open", page: 1)

    socket
    |> assign(:open_project_count, open_project_count)
    |> assign(:closed_project_count, Projects.count_visible_projects(user, state: "closed"))
    |> assign(:projects, Enum.take(projects, @project_limit))
  end

  # The forum reads through the same viewer-authorized scope `/forum` composes,
  # one row per topic, so the panel cannot name a board the board list would
  # not -- on a refresh no less than on a mount.
  defp assign_posts(socket) do
    assign(
      socket,
      :posts,
      Forum.list_recent_posts(
        operator?: Accounts.admin?(socket.assigns.current_user),
        limit: @post_limit
      )
    )
  end

  # Mount reads the shared cache, because every signed-in page load would
  # otherwise rebuild the projection and the cache exists to stop exactly that.
  # A live refresh bypasses it, because a rail told the ledger moved and then
  # handed the cached answer would render the state it was told had changed.
  defp assign_changelog(socket, opts \\ []) do
    assign(socket, :changelog, changelog_entries(opts))
  end

  defp assign_repositories(socket) do
    repositories = Repositories.list_visible_repositories(socket.assigns.current_user)

    socket
    |> assign(:any_repository?, repositories != [])
    |> stream(:repositories, repositories)
  end

  # The ledger is a bounded public projection and can legitimately refuse. An
  # empty rail is the honest answer; the home page should not crash over it.
  #
  # Its agent-layer rows carry no authored note, which is what left the rail
  # rendering a column of bare relative times. A row states what it is or it
  # does not render.
  defp changelog_entries(opts) do
    case Changelog.timeline(@repo, opts) do
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

  # A reader mid-way through authorizing a terminal is not here to be sold the
  # product; they are here because a sign-in stands between them and one
  # approval. Showing them the landing page would be the third screen in a row
  # that does not mention what they are actually doing, so this says it: the
  # terminal, its code, and where the sign-in puts them next.
  #
  # None of the sign-in controls need the code threaded through them. It is in
  # the session already, so the command bar's control returns the reader to the
  # approval exactly as this one does.
  def render(%{device_user_code: code} = assigns) when is_binary(code) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <main id="device-sign-in" class="mx-auto w-full max-w-lg space-y-8 px-4 py-16">
        <.header>
          Sign in to authorize your terminal
          <:subtitle>
            Your terminal is waiting on this code. Signing in brings you straight back to
            the approval — you will not need to enter it again.
          </:subtitle>
        </.header>

        <.card>
          <div class="space-y-6">
            <div>
              <p class="text-sm text-muted-foreground">Code shown in your terminal</p>
              <code id="device-sign-in-code" class="text-2xl font-semibold tracking-widest">
                {@device_user_code}
              </code>
            </div>
            <p class="text-sm text-muted-foreground">
              Check that it matches before you approve. OpenAgents signs you in through GitHub;
              your GitHub token stays here and never reaches the terminal.
            </p>
            <.github_login id="device-signin" size={:lg} />
          </div>
        </.card>
      </main>
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

        <%!-- The band leads with the product a reader can have in one command,
        not with the platform behind it. The install line is the only action
        here on purpose: signing in is what the command bar is for, and a hero
        that offers two ways to start makes the reader choose before they know
        enough to choose well.

        It closes with a rule rather than running straight into the feature
        grid, so the claim and the way to act on it read as one band. --%>
        <Landing.hero
          title="Coder."
          title_lead="Introducing"
          description="Your all-in-one coding agent."
          rule
        >
          <%!-- Commented out rather than deleted, and for the same reason as
          the figure below: the shape is right and what it announces does not
          exist yet. A pill is a link, and one that opens a post nobody has
          written spends the reader's attention and returns none of it.
          Restore it when there is a post to point at.

          <:eyebrow>
            <Landing.announce
              lead="Coder is here"
              detail="Install it in one command"
              navigate={~p"/coder"}
            />
          </:eyebrow>
          --%>

          <:command>
            <Landing.install_command id="home-install-command" command={@install_command} />
          </:command>

          <%!-- Two lines, not one sentence. The first is what the reader gets
          and the second is what it costs them to get it, and running them
          together would let the second read as a condition on the credit
          rather than on the account. --%>
          <:note>
            Every new account starts with $20 of credit.<br />Login with GitHub required.
          </:note>

          <:links>
            <.button navigate={~p"/docs"} variant={:ghost} size={:sm} class="hero__link">
              Read the docs <.icon name="chevron-right" />
            </.button>
            <.button navigate={~p"/changelog"} variant={:ghost} size={:sm} class="hero__link">
              Changelog <.icon name="chevron-right" />
            </.button>
            <.button
              navigate={~p"/OpenAgentsInc/openagents.com"}
              variant={:ghost}
              size={:sm}
              class="hero__link"
            >
              Open source <.icon name="chevron-right" />
            </.button>
          </:links>

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

        <Landing.feature_grid title="One agent, wired to the forge it ships from.">
          <:item title="A session, or a command" icon="terminal">
            Run it bare and it opens a coding session. Give it a command and it runs
            that instead. Three names, one binary.
          </:item>
          <:item title="Where your code already is" icon="folder">
            It reads files and runs shell commands in the checkout you are standing in,
            on your machine, under your account.
          </:item>
          <:item title="Issues and projects" icon="file-document">
            Read and write issues, labels, milestones, assignees, and projects from the
            session, over the GitHub-shaped API this forge serves.
          </:item>
          <:item title="Push, already authenticated" icon="branch">
            One command installs a Git credential helper scoped to this origin. After
            it, plain <code>git push</code> works, and every accepted push leaves a
            receipt.
          </:item>
          <:item title="Sessions that survive" icon="memory-on-remember">
            The transcript is written to the server as the session runs, so resuming
            picks up where you stopped — on this machine or another one.
          </:item>
          <:item title="Plugins in a sandbox" icon="plugin">
            Extra tools ship as WebAssembly, mounted read-only and pinned to a digest.
            Ask for one and the session loads it.
          </:item>
          <:item title="Delegation" icon="robot">
            Hand part of the work to a child agent, on a rented sandbox or on a machine
            you paired yourself, and keep going.
          </:item>
          <:item title="Credit, not a bill" icon="credits">
            Every call meters against one balance, and the session can tell you what is
            left. No plan to pick, and no ceiling on how long a session runs.
          </:item>
        </Landing.feature_grid>

        <Landing.faq title="Questions">
          <:item question="What does that install command do?" open>
            <p>
              It detects your operating system and processor, downloads the matching
              build, fetches the checksum file separately, and refuses anything it
              cannot verify — the bytes are never made executable before the
              comparison succeeds. Then it links three names, <code>openagents</code>, <code>coder</code>, and <code>oa</code>, into <code>~/.openagents/bin</code>. macOS builds are signed and notarized, so
              Gatekeeper admits them without a right-click override.
            </p>
          </:item>
          <:item question="Do I need an account?">
            <p>
              Yes, and identity comes from GitHub — there is no separate
              OpenAgents password. Signing in from the terminal runs the device flow: it prints a
              code and a URL, you approve it in a browser, and the token lands in your
              operating system's credential store. Your GitHub token stays here and
              never reaches the terminal.
            </p>
          </:item>
          <:item question="Which model answers?">
            <p>
              One you picked, for the whole session. The
              <.link navigate={~p"/models"}>models page</.link>
              lists every model this deployment serves with its rates and context
              window, and no call is ever answered by a different model than the one
              you asked for.
            </p>
          </:item>
          <:item question="Is this the whole application?">
            <p>
              Yes. The repository is AGPL-3.0, the forge Coder talks to is this site,
              and every surface on it is built from the same component system
              documented in the component library.
            </p>
          </:item>
        </Landing.faq>

        <Landing.cta
          title="Put it in your terminal."
          description="One command, and the agent is where the work is."
        >
          <:actions>
            <.button navigate={~p"/docs/install-cli"} variant={:primary} size={:lg}>
              Install Coder
            </.button>
          </:actions>
        </Landing.cta>

        <Landing.landing_footer
          tagline="Your all-in-one coding agent, wired to the forge it ships from."
          copyright="© 2026 OpenAgents, Inc."
          note="AGPL-3.0. Every surface here is in the repository."
        >
          <:column title="Coder">
            <.link navigate={~p"/docs/install-cli"}>Install</.link>
            <.link navigate={~p"/docs"}>Documentation</.link>
            <.link navigate={~p"/models"}>Models</.link>
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
