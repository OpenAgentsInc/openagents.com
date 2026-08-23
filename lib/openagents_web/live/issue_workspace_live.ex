defmodule OpenAgentsWeb.IssueWorkspaceLive do
  @moduledoc """
  Every issue you can read, across every repository.

  The sidebar's **Issues** row points here. It used to point at a repository —
  whichever one the page you were on named, or, on a page that named none, the
  first repository in your workspace alphabetically — so the same row led
  somewhere different depending on where you clicked it from, and disappeared
  for an account with no membership. A row in the app's own navigation has to
  mean one thing everywhere. `/:owner/:repo/issues` still exists and is
  unchanged; it is reached from the repository's own tabs, which is where a
  repository-scoped list belongs.

  ## What it opens on

  Open issues in every repository you can read, newest first.

  GitHub's global issue list opens on **assigned to you**, and that is the
  right default there because on GitHub an assignee is how work is handed
  over. It is the wrong default here. Issues on this forge arrive mostly by
  import and through the API, and most of them carry no assignee at all, so
  opening on "assigned to you" would show almost every account an empty page
  and hide the thing they came to see. A default that hides the answer is
  worse than one that shows more than you asked for. Assigned and opened-by
  are one control away, and both are honest once the data supports them.

  ## Authorization

  Every read goes through `OpenAgents.Issues.list_visible_issues_page/2`,
  which joins the issue table to `OpenAgents.Repositories.readable_by/2` — the
  one predicate every repository surface composes. There is no second rule
  here to fall out of step with the first, and no filter this view offers can
  widen the set: filters narrow an already-authorized query.

  This view is read-only. Changing an issue's state or its assignees needs a
  writable membership in that issue's repository, which is a different
  question for every row on the page, so triage stays on the repository's own
  list where the answer is settled once.

  ## Bound

  One page is `OpenAgents.Issues.per_page/0` rows — 25 — and the page number
  is clamped to 10,000 by `OpenAgents.Issues.parse_page/1`, so the deepest
  reachable offset is fixed no matter what the query string says. Nothing here
  loads an unbounded list.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.Components.IssuePresentation
  alias OpenAgentsWeb.UI.Circle

  @involvements [
    {"Everyone", "all"},
    {"Assigned to you", "assigned"},
    {"Opened by you", "created"}
  ]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Repositories.subscribe_all_issues()
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

  # Live updates across every repository. Any committed issue write anywhere
  # re-reads the current page through this viewer's own authorization — the
  # same `readable_by` predicate the initial load used — so a viewer who keeps
  # the page open converges instead of drifting. Bursts coalesce: each change
  # (re)arms one timer and only the last fires a re-read.
  def handle_info({:issues_changed, _repository_id}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(:refresh_issues_now, socket) do
    {:noreply, socket |> assign(:refresh_timer_ref, nil) |> load()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @refresh_debounce_ms if Application.compile_env(:openagents, :runtime_environment) == :test,
                         do: 0,
                         else: 250

  defp schedule_refresh(socket) do
    if @refresh_debounce_ms == 0 do
      # Tests refresh synchronously so assertions do not depend on time.
      load(socket)
    else
      rearm_refresh(socket)
    end
  end

  defp rearm_refresh(socket) do
    case socket.assigns.refresh_timer_ref do
      nil ->
        assign(
          socket,
          :refresh_timer_ref,
          Process.send_after(self(), :refresh_issues_now, @refresh_debounce_ms)
        )

      ref when is_reference(ref) ->
        Process.cancel_timer(ref)

        assign(
          socket,
          :refresh_timer_ref,
          Process.send_after(self(), :refresh_issues_now, @refresh_debounce_ms)
        )
    end
  end

  def handle_params(params, _url, socket) do
    filters = read_filters(params, socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(:state, normalize_state(params["state"]))
     |> assign(:page, Issues.parse_page(params["page"]))
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filter))
     |> load()}
  end

  # One form drives every filter, so one change event carries the complete
  # desired set and patching replaces it wholesale.
  def handle_event("filter", params, socket) do
    filters = %{
      "involvement" => normalize_involvement(params["involvement"], socket.assigns.current_user),
      "q" => blank_to_nil(params["q"])
    }

    {:noreply, push_patch(socket, to: issues_path(filters, %{"state" => socket.assigns.state}))}
  end

  def handle_event(_unsupported_event, _params, socket) do
    {:noreply, put_flash(socket, :error, "That action is not available here.")}
  end

  defp read_filters(params, user) do
    %{
      "involvement" => normalize_involvement(params["involvement"], user),
      "q" => blank_to_nil(params["q"])
    }
  end

  # A hand-edited query string cannot smuggle an option into the context call:
  # anything unrecognized becomes the default.
  defp normalize_involvement(_involvement, nil), do: "all"

  defp normalize_involvement(involvement, _user) when involvement in ~w(assigned created),
    do: involvement

  defp normalize_involvement(_involvement, _user), do: "all"

  defp normalize_state("closed"), do: "closed"
  defp normalize_state("all"), do: "all"
  defp normalize_state(_state), do: "open"

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp issues_path(filters, extra) do
    query =
      filters
      |> Map.merge(extra)
      |> Enum.reject(fn {_key, value} -> value in [nil, "", "all"] end)
      |> Map.new()

    ~p"/issues?#{query}"
  end

  defp load(socket) do
    user = socket.assigns.current_user
    %{filters: filters, state: state, page: page} = socket.assigns

    opts = involvement_opts(user, filters["involvement"]) ++ [q: filters["q"]]
    count_opts = Keyword.put(opts, :page, 1)

    {issues, total} =
      Issues.list_visible_issues_page(user, opts ++ [state: state, page: page])

    socket
    |> assign(:progress, Issues.progress_map(issues, user))
    |> assign(:open_count, Issues.count_visible_issues(user, count_opts ++ [state: "open"]))
    |> assign(:closed_count, Issues.count_visible_issues(user, count_opts ++ [state: "closed"]))
    |> assign(:total_count, total)
    |> assign(:issues_count, length(issues))
    |> stream(:issues, issues, reset: true)
  end

  # The view's involvement words become the context's own options. "Assigned"
  # reads the assignee snapshot by login; "opened by" matches either the
  # durable author link or an imported login.
  defp involvement_opts(nil, _involvement), do: []
  defp involvement_opts(user, "assigned"), do: [assignee: user.github_login]
  defp involvement_opts(user, "created"), do: [author: user]
  defp involvement_opts(_user, _all), do: []

  defp involvement_options(nil), do: [{"Everyone", "all"}]
  defp involvement_options(_user), do: @involvements

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Issues"
      subtitle="Across every repository you can read"
      wide
    >
      <Circle.issue_toolbar>
        <:leading>
          <Circle.view_tabs>
            <:tab
              label={"#{@open_count} Open"}
              patch={issues_path(@filters, %{"state" => "open"})}
              selected={@state == "open"}
            />
            <:tab
              label={"#{@closed_count} Closed"}
              patch={issues_path(@filters, %{"state" => "closed"})}
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
        <.form for={@filter_form} phx-change="filter" id="workspace-issue-filter-form">
          <.input
            type="search"
            name="q"
            value={@filters["q"]}
            placeholder="Search issues"
            aria-label="Search issues"
            class="!w-56"
          />
          <.input
            type="select"
            name="involvement"
            value={@filters["involvement"]}
            options={@involvements}
            aria-label="Filter by your involvement"
          />
        </.form>
      </div>

      <%!-- Two different emptinesses, two different next steps. An account
      with nowhere to read is not looking at a filter that matched nothing. --%>
      <.empty
        :if={@issues_count == 0 and not @any_repository?}
        id="workspace-issues-no-repositories"
        title="No repositories yet"
      >
        <%= if @current_user do %>
          Issues appear here once you can read a repository.
          <.link navigate={~p"/repositories/new"} data-variant="link" class="btn px-0">
            Create one
          </.link>
          or
          <.link navigate={~p"/repositories/import/github"} data-variant="link" class="btn px-0">
            import one from GitHub
          </.link>
          , and its issues arrive with it.
        <% else %>
          Sign in with GitHub to see issues from repositories you can read.
          <.github_login id="workspace-issues-signin" size={:sm} />
        <% end %>
      </.empty>

      <.empty
        :if={@issues_count == 0 and @any_repository?}
        id="workspace-issues-empty"
        title={empty_title(@state, @filters)}
      >
        {empty_body(@filters)}
      </.empty>

      <div :if={@issues_count > 0} id="workspace-issues" phx-update="stream" class="issue-list">
        <IssuePresentation.issue_row
          :for={{id, issue} <- @streams.issues}
          id={id}
          issue={issue}
          progress={@progress[issue.id]}
          repository={IssuePresentation.repository_path(issue)}
          navigate={~p"/#{issue.repository.owner}/#{issue.repository.name}/issues/#{issue.number}"}
        />
      </div>

      <nav :if={@total_count > Issues.per_page()} class="issue-pagination" aria-label="Pages">
        <span class="issue-pagination__status">
          Showing {@issues_count} of {@total_count}
        </span>
        <span class="issue-pagination__controls">
          <.link
            :if={@page > 1}
            patch={issues_path(@filters, %{"state" => @state, "page" => @page - 1})}
            class="btn"
            data-variant="ghost"
            data-size="sm"
          >
            Previous
          </.link>
          <.link
            :if={@page * Issues.per_page() < @total_count}
            patch={issues_path(@filters, %{"state" => @state, "page" => @page + 1})}
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

  defp empty_title(state, %{"involvement" => "assigned"}),
    do: "No #{state} issues assigned to you"

  defp empty_title(state, %{"involvement" => "created"}), do: "No #{state} issues you opened"
  defp empty_title(state, _filters), do: "No #{state} issues"

  defp empty_body(%{"q" => q}) when is_binary(q),
    do: "Nothing matches that search. Clear it to see the rest."

  defp empty_body(%{"involvement" => involvement}) when involvement != "all",
    do: "Choose Everyone to see the rest of the issues you can read."

  defp empty_body(_filters),
    do: "Issues from every repository you can read arrive here as they are opened."
end
