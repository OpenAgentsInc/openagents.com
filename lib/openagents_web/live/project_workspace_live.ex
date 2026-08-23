defmodule OpenAgentsWeb.ProjectWorkspaceLive do
  @moduledoc """
  Every project you can read, across every repository.

  The sidebar's **Projects** row points here, for the same reason
  `OpenAgentsWeb.IssueWorkspaceLive` exists: the row used to address whichever
  repository the current page named, so it led somewhere different depending
  on where it was clicked from. `/:owner/:repo/projects` is unchanged and
  still owns creating, closing, and deleting a project, because each of those
  needs a writable membership in one named repository.

  ## What it opens on

  Open projects in every repository you can read, newest first, with the
  repository each belongs to beside it. A project's own board is one click
  away.

  ## Authorization

  `OpenAgents.Projects.list_visible_projects_page/2` joins the project table
  to `OpenAgents.Repositories.readable_by/2`, the same predicate every
  repository surface composes, so a project in a repository you have no
  membership in cannot appear. This view reads and does not write.

  ## Bound

  One page is `OpenAgents.Projects.per_page/0` rows — 25 — with the page
  number clamped the same way the issue lists clamp theirs.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Projects
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.UI.Circle

  @involvements [{"Everyone", "all"}, {"Created by you", "created"}]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Repositories.subscribe_all_projects()
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:involvements, involvement_options(user))
     |> assign(:refresh_timer_ref, nil)
     |> assign(
       :any_repository?,
       Repositories.any_visible_repository?(socket.assigns.current_user)
     )}
  end

  # Live updates across every repository. Any committed project write anywhere
  # re-reads the current page through this viewer's own authorization — the
  # same `readable_by` predicate the initial load used — so a viewer who keeps
  # the page open converges instead of drifting. Bursts coalesce: each change
  # (re)arms one timer and only the last fires a re-read.
  def handle_info({:projects_changed, _repository_id}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(:refresh_projects_now, socket) do
    {:noreply, socket |> assign(:refresh_timer_ref, nil) |> load()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @refresh_debounce_ms if Application.compile_env(:openagents, :runtime_environment) == :test,
                         do: 0,
                         else: 250

  # Zero debounce means tests: refresh synchronously on the change message so
  # assertions need no waiting.
  defp schedule_refresh(socket) do
    if @refresh_debounce_ms == 0,
      do: load(socket),
      else: schedule_debounced_refresh(socket)
  end

  defp schedule_debounced_refresh(socket) do
    case socket.assigns.refresh_timer_ref do
      nil ->
        assign(
          socket,
          :refresh_timer_ref,
          Process.send_after(self(), :refresh_projects_now, @refresh_debounce_ms)
        )

      ref when is_reference(ref) ->
        Process.cancel_timer(ref)

        assign(
          socket,
          :refresh_timer_ref,
          Process.send_after(self(), :refresh_projects_now, @refresh_debounce_ms)
        )
    end
  end

  def handle_params(params, _url, socket) do
    filters = %{
      "involvement" => normalize_involvement(params["involvement"], socket.assigns.current_user)
    }

    {:noreply,
     socket
     |> assign(:state, normalize_state(params["state"]))
     |> assign(:page, Projects.parse_page(params["page"]))
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filter))
     |> load()}
  end

  def handle_event("filter", params, socket) do
    filters = %{
      "involvement" => normalize_involvement(params["involvement"], socket.assigns.current_user)
    }

    {:noreply, push_patch(socket, to: projects_path(filters, %{"state" => socket.assigns.state}))}
  end

  def handle_event(_unsupported_event, _params, socket) do
    {:noreply, put_flash(socket, :error, "That action is not available here.")}
  end

  defp normalize_involvement(_involvement, nil), do: "all"
  defp normalize_involvement("created", _user), do: "created"
  defp normalize_involvement(_involvement, _user), do: "all"

  defp normalize_state("closed"), do: "closed"
  defp normalize_state("all"), do: "all"
  defp normalize_state(_state), do: "open"

  defp projects_path(filters, extra) do
    query =
      filters
      |> Map.merge(extra)
      |> Enum.reject(fn {_key, value} -> value in [nil, "", "all"] end)
      |> Map.new()

    ~p"/projects?#{query}"
  end

  defp load(socket) do
    user = socket.assigns.current_user
    %{filters: filters, state: state, page: page} = socket.assigns

    opts = involvement_opts(user, filters["involvement"])

    {projects, total} =
      Projects.list_visible_projects_page(user, opts ++ [state: state, page: page])

    socket
    |> assign(:open_count, Projects.count_visible_projects(user, opts ++ [state: "open"]))
    |> assign(:closed_count, Projects.count_visible_projects(user, opts ++ [state: "closed"]))
    |> assign(:total_count, total)
    |> assign(:projects_count, length(projects))
    |> assign(:projects, projects)
  end

  defp involvement_opts(nil, _involvement), do: []
  defp involvement_opts(user, "created"), do: [owner: user]
  defp involvement_opts(_user, _all), do: []

  defp involvement_options(nil), do: [{"Everyone", "all"}]
  defp involvement_options(_user), do: @involvements

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Projects"
      subtitle="Across every repository you can read"
      wide
    >
      <Circle.issue_toolbar>
        <:leading>
          <Circle.view_tabs>
            <:tab
              label={"#{@open_count} Open"}
              patch={projects_path(@filters, %{"state" => "open"})}
              selected={@state == "open"}
            />
            <:tab
              label={"#{@closed_count} Closed"}
              patch={projects_path(@filters, %{"state" => "closed"})}
              selected={@state == "closed"}
            />
          </Circle.view_tabs>
        </:leading>

        <:actions>
          <.link navigate={~p"/repositories"} class="btn" data-variant="ghost" data-size="sm">
            <.icon name="branch" /> Repositories
          </.link>
        </:actions>
      </Circle.issue_toolbar>

      <div class="issue-filters">
        <.form for={@filter_form} phx-change="filter" id="workspace-project-filter-form">
          <.input
            type="select"
            name="involvement"
            value={@filters["involvement"]}
            options={@involvements}
            aria-label="Filter by your involvement"
          />
        </.form>
      </div>

      <.empty
        :if={@projects_count == 0 and not @any_repository?}
        id="workspace-projects-no-repositories"
        title="No repositories yet"
      >
        <%= if @current_user do %>
          Projects belong to a repository.
          <.link navigate={~p"/repositories/new"} data-variant="link" class="btn px-0">
            Create one
          </.link>
          or
          <.link navigate={~p"/repositories/import/github"} data-variant="link" class="btn px-0">
            import one from GitHub
          </.link>
          to start a board.
        <% else %>
          Sign in with GitHub to see projects from repositories you can read.
          <.github_login id="workspace-projects-signin" size={:sm} />
        <% end %>
      </.empty>

      <.empty
        :if={@projects_count == 0 and @any_repository?}
        id="workspace-projects-empty"
        title={empty_title(@state, @filters)}
      >
        {empty_body(@filters)}
      </.empty>

      <div :if={@projects_count > 0} id="workspace-projects" class="project-index">
        <div :for={project <- @projects} class="project-index__row">
          <Circle.project_row
            name={project.title}
            navigate={
              ~p"/#{project.repository.owner}/#{project.repository.name}/projects/#{project.number}"
            }
            status_category={if project.state == "closed", do: :completed, else: :unstarted}
            status_label={String.capitalize(project.state)}
            labels={[%{name: repository_path(project), tone: :neutral}]}
          />
        </div>
      </div>

      <nav :if={@total_count > Projects.per_page()} class="issue-pagination" aria-label="Pages">
        <span class="issue-pagination__status">
          Showing {@projects_count} of {@total_count}
        </span>
        <span class="issue-pagination__controls">
          <.link
            :if={@page > 1}
            patch={projects_path(@filters, %{"state" => @state, "page" => @page - 1})}
            class="btn"
            data-variant="ghost"
            data-size="sm"
          >
            Previous
          </.link>
          <.link
            :if={@page * Projects.per_page() < @total_count}
            patch={projects_path(@filters, %{"state" => @state, "page" => @page + 1})}
            class="btn"
            data-variant="ghost"
            data-size="sm"
          >
            Next
          </.link>
        </span>
      </nav>
    </Layouts.app>
    """
  end

  defp repository_path(%{repository: %{owner: owner, name: name}}), do: "#{owner}/#{name}"

  defp empty_title(state, %{"involvement" => "created"}), do: "No #{state} projects you created"
  defp empty_title(state, _filters), do: "No #{state} projects"

  defp empty_body(%{"involvement" => "created"}),
    do: "Choose Everyone to see the rest of the projects you can read."

  defp empty_body(_filters),
    do: "A project you can read in any repository appears here once it is created."
end
