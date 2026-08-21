defmodule OpenAgentsWeb.IssueIndexLive do
  @moduledoc """
  Lists issues for a repository.

  Reading is public on a public repository, the way code browsing already is.
  Interacting — opening an issue, commenting on the detail page — needs a
  signed-in person, and triage (state, assignees) needs a writable membership,
  so every control that writes checks its authority at the server and not only
  in what the template renders.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.Labels
  alias OpenAgents.Milestones
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.OG
  alias OpenAgentsWeb.UI.Circle

  @filter_keys ~w(label assignee milestone q)

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :current_scope, socket.assigns[:current_scope])}
  end

  def handle_params(%{"owner" => owner, "repo" => repo} = params, _url, socket) do
    with {:ok, repository} <- visible_repository(owner, repo, socket.assigns.current_user) do
      if connected?(socket), do: Repositories.subscribe_issues(repository.id)

      user = socket.assigns.current_user
      can_write = Repositories.writable?(repository, user)
      filters = read_filters(params)

      socket =
        socket
        |> assign(:owner, owner)
        |> assign(:repo, repo)
        |> assign(:repository, repository)
        |> assign(:current_user, user)
        |> assign(:can_write, can_write)
        |> assign(:can_participate, Repositories.issue_participant?(repository, user))
        |> assign(:state, normalize_state(params["state"]))
        |> assign(:page, Issues.parse_page(params["page"]))
        |> assign(:filters, filters)
        |> assign(:filter_form, to_form(filters, as: :filter))
        |> assign(:label_options, Labels.list_labels(repository))
        |> assign(:assignable, Repositories.list_assignable_users(repository))
        |> assign(:milestone_options, Milestones.list_milestones(repository))
        |> load()
        |> assign(:og, OG.meta(OG.repo_card_for(repository)))

      {:noreply, socket}
    else
      :error -> raise OpenAgentsWeb.PublicNotFoundError, message: "repository not found"
    end
  end

  # Filters arrive as query params; anything unrecognized is dropped so a
  # hand-edited URL cannot smuggle an option into the context call.
  defp read_filters(params) do
    Map.new(@filter_keys, fn key -> {key, blank_to_nil(params[key])} end)
  end

  # One form drives every filter, so one change event carries the complete
  # desired set and patching replaces it wholesale.
  def handle_event("filter", params, socket) do
    filters = Map.new(@filter_keys, fn key -> {key, blank_to_nil(params[key])} end)
    apply_filters(socket, filters)
  end

  def handle_event("set_state", %{"id" => id, "state" => state} = params, socket)
      when state in ~w(open closed) do
    socket = refresh_authority(socket)

    if socket.assigns.can_write do
      attrs =
        case state do
          "open" -> %{"state" => "open", "state_reason" => nil}
          "closed" -> %{"state" => "closed", "state_reason" => params["reason"]}
        end

      Issues.update_issue(issue!(socket, id), attrs, socket.assigns.current_user)
      {:noreply, load(socket)}
    else
      {:noreply, put_flash(socket, :error, "Only repository members can change issue state.")}
    end
  end

  def handle_event("toggle_assignee", %{"id" => id, "login" => login}, socket) do
    socket = refresh_authority(socket)

    if socket.assigns.can_write do
      issue = issue!(socket, id)

      if Enum.any?(issue.assignees || [], &(&1["login"] == login)) do
        Issues.remove_assignees(issue, [login])
      else
        Issues.add_assignees(issue, [login])
      end

      {:noreply, load(socket)}
    else
      {:noreply, put_flash(socket, :error, "Only repository members can change assignees.")}
    end
  end

  def handle_event(_unsupported_event, _params, socket) do
    {:noreply, put_flash(socket, :error, "That issue action is not available.")}
  end

  # Live updates: any committed issue write in this repository re-reads the
  # current page through this viewer's own authorization, so two people
  # triaging together converge instead of drifting.
  def handle_info({:issues_changed, repository_id}, socket) do
    if repository_id == socket.assigns.repository.id,
      do: {:noreply, socket |> refresh_authority() |> load()},
      else: {:noreply, socket}
  end

  defp refresh_authority(socket) do
    repository = socket.assigns.repository
    user = socket.assigns.current_user

    socket
    |> assign(:can_write, Repositories.writable?(repository, user))
    |> assign(:can_participate, Repositories.issue_participant?(repository, user))
  end

  defp apply_filters(socket, filters) do
    {:noreply,
     push_patch(socket, to: issues_path(socket.assigns.owner, socket.assigns.repo, filters))}
  end

  defp issues_path(owner, repo, filters, extra \\ %{}) do
    query =
      filters
      |> Map.merge(extra)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    ~p"/#{owner}/#{repo}/issues?#{query}"
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp normalize_state("closed"), do: "closed"
  defp normalize_state(_state), do: "open"

  defp visible_repository(owner, repo, user) do
    try do
      {:ok, Repositories.get_visible_by_path!(owner, repo, user)}
    rescue
      Ecto.NoResultsError -> :error
    end
  end

  # Reloading rather than patching one row: closing an issue while the Open tab
  # is showing has to remove it from the list and change both tab counts, and a
  # row that stays visible after being closed is worse than a reload.
  defp load(socket) do
    repository = socket.assigns.repository
    %{filters: filters, state: state, page: page} = socket.assigns

    opts =
      filters
      |> Keyword.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
      |> Keyword.put(:state, state)
      |> Keyword.put(:page, page)

    count_opts = Keyword.drop(opts, [:page])

    {issues, total} = Issues.list_issues_page(repository, opts)

    socket
    |> assign(
      :open_count,
      Issues.count_issues(repository, Keyword.put(count_opts, :state, "open"))
    )
    |> assign(
      :closed_count,
      Issues.count_issues(repository, Keyword.put(count_opts, :state, "closed"))
    )
    |> assign(:total_count, total)
    |> assign(:issues_count, length(issues))
    |> stream(:issues, issues, reset: true)
  end

  # `JS.push` sends the id as a number; a `phx-value-` attribute would send a
  # string. The handler takes whichever arrives.
  defp issue!(socket, id) when is_integer(id),
    do: Issues.get_issue!(socket.assigns.repository, id)

  defp issue!(socket, id) when is_binary(id),
    do: Issues.get_issue!(socket.assigns.repository, String.to_integer(id))

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Issues"
      wide
    >
      <Circle.issue_toolbar>
        <:leading>
          <Circle.view_tabs>
            <:tab
              label={"#{@open_count} Open"}
              patch={issues_path(@owner, @repo, @filters, %{"state" => "open"})}
              selected={@state == "open"}
            />
            <:tab
              label={"#{@closed_count} Closed"}
              patch={issues_path(@owner, @repo, @filters, %{"state" => "closed"})}
              selected={@state == "closed"}
            />
          </Circle.view_tabs>
        </:leading>

        <:actions>
          <.link
            :if={@can_write}
            navigate={~p"/#{@owner}/#{@repo}/labels"}
            class="btn"
            data-variant="ghost"
            data-size="sm"
          >
            <.icon name="tag" /> Labels
          </.link>
          <.link
            :if={@can_write}
            navigate={~p"/#{@owner}/#{@repo}/milestones"}
            class="btn"
            data-variant="ghost"
            data-size="sm"
          >
            <.icon name="flag" /> Milestones
          </.link>
          <.link
            :if={@can_participate}
            navigate={~p"/#{@owner}/#{@repo}/issues/new"}
            class="btn"
            data-variant="primary"
            data-size="sm"
          >
            New issue
          </.link>
        </:actions>
      </Circle.issue_toolbar>

      <div class="issue-filters">
        <.form for={@filter_form} phx-change="filter" id="issue-filter-form">
          <.input
            type="search"
            name="q"
            value={@filters["q"]}
            placeholder="Search issues"
            aria-label="Search issues"
            class="!w-56"
          />
          <.input
            :if={@milestone_options != []}
            type="select"
            name="milestone"
            value={@filters["milestone"]}
            options={Enum.map(@milestone_options, &{&1.title, Integer.to_string(&1.number)})}
            prompt="All milestones"
            aria-label="Filter by milestone"
          />
          <.input
            :if={@label_options != []}
            type="select"
            name="label"
            value={@filters["label"]}
            options={Enum.map(@label_options, &{&1.name, &1.name})}
            prompt="All labels"
            aria-label="Filter by label"
          />
          <.input
            :if={@assignable != []}
            type="select"
            name="assignee"
            value={@filters["assignee"]}
            options={Enum.map(@assignable, &{&1.github_login, &1.github_login})}
            prompt="Everyone"
            aria-label="Filter by assignee"
          />
        </.form>
      </div>

      <.empty
        :if={@issues_count == 0}
        id="issues-empty"
        title={"No #{@state} issues"}
      >
        <%= if @can_participate do %>
          Issues will show up here once they are created.
        <% else %>
          Nothing matches here yet.
        <% end %>
      </.empty>

      <div :if={@issues_count > 0} id="issues" phx-update="stream" class="issue-list">
        <Circle.issue_row
          :for={{id, issue} <- @streams.issues}
          id={id}
          identifier={"##{issue.number}"}
          title={issue.title}
          navigate={~p"/#{@owner}/#{@repo}/issues/#{issue.number}"}
          status_category={category(issue)}
          status_label={status_label(issue)}
          labels={labels(issue)}
          assignee={assignee(issue)}
          created={"opened #{relative(issue.inserted_at)} ago"}
          author={author(issue)}
          comments={issue.comments}
        >
          <:state :if={@can_write}>
            <Circle.field_menu
              id={"row-state-#{issue.id}"}
              label={"Change the state of issue ##{issue.number}"}
            >
              <:trigger>
                <Circle.issue_state state={issue.state} reason={issue.state_reason} />
              </:trigger>
              <Circle.field_menu_item
                :for={{label, state, reason} <- state_options()}
                label={label}
                mode={:choice}
                selected={issue.state == state and close_reason(issue) == reason}
                closes={"row-state-#{issue.id}"}
                on_select={JS.push("set_state", value: %{id: issue.id, state: state, reason: reason})}
              >
                <:glyph><Circle.issue_state state={state} reason={reason} /></:glyph>
              </Circle.field_menu_item>
            </Circle.field_menu>
          </:state>
          <:people :if={@can_write}>
            <Circle.field_menu
              id={"row-assignee-#{issue.id}"}
              label={"Assign issue ##{issue.number}"}
              align={:end}
            >
              <:trigger>
                <Circle.assignee
                  name={assignee(issue) && assignee(issue)[:name]}
                  src={assignee(issue) && assignee(issue)[:src]}
                />
              </:trigger>
              <Circle.field_menu_item
                :for={user <- @assignable}
                label={user.github_login}
                selected={assigned?(issue, user.github_login)}
                on_select={
                  JS.push("toggle_assignee", value: %{id: issue.id, login: user.github_login})
                }
              >
                <:glyph><Circle.assignee name={user.github_login} size={:sm} /></:glyph>
              </Circle.field_menu_item>
            </Circle.field_menu>
          </:people>
        </Circle.issue_row>
      </div>

      <nav :if={@total_count > Issues.per_page()} class="issue-pagination" aria-label="Pages">
        <span class="issue-pagination__status">
          Showing {@issues_count} of {@total_count}
        </span>
        <span class="issue-pagination__controls">
          <.link
            :if={@page > 1}
            patch={issues_path(@owner, @repo, @filters, %{"state" => @state, "page" => @page - 1})}
            class="btn"
            data-variant="ghost"
            data-size="sm"
          >
            Previous
          </.link>
          <.link
            :if={@page * Issues.per_page() < @total_count}
            patch={issues_path(@owner, @repo, @filters, %{"state" => @state, "page" => @page + 1})}
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

  # GitHub's two states, and nothing invented on top of them. `not_planned` is
  # the one close reason with a distinct reading, so it takes the cancelled
  # glyph; every other close is a completion.
  defp category(%{state: "closed", state_reason: "not_planned"}), do: :canceled
  defp category(%{state: "closed"}), do: :completed
  defp category(_issue), do: :unstarted

  defp status_label(%{state: "closed", state_reason: "not_planned"}), do: "Closed as not planned"
  defp status_label(%{state: "closed"}), do: "Closed"
  defp status_label(_issue), do: "Open"

  # `duplicate` is rendered when it arrives from the API but is not offered:
  # the menu has nowhere to record which issue it duplicates, and a duplicate
  # that does not say of what is worse than a plain close.
  defp state_options do
    [
      {"Open", "open", nil},
      {"Closed as completed", "closed", "completed"},
      {"Closed as not planned", "closed", "not_planned"}
    ]
  end

  defp close_reason(%{state: "closed", state_reason: reason}), do: reason || "completed"
  defp close_reason(_issue), do: nil

  defp assigned?(issue, login), do: Enum.any?(issue.assignees || [], &(&1["login"] == login))

  # A label carries a colour on GitHub; the row takes a tone from our ladder
  # rather than that hex, so the list stays in one palette.
  defp labels(%{labels: labels}) when is_list(labels) do
    Enum.map(labels, fn label ->
      %{name: label["name"] || label[:name] || "label", tone: :neutral}
    end)
  end

  defp labels(_issue), do: []

  # GitHub issues carry many assignees; the row shows the first, which is the
  # one GitHub itself treats as `assignee`.
  defp assignee(%{assignees: [first | _rest]}) when is_map(first) do
    %{
      name: first["login"] || first[:login],
      src: first["avatar_url"] || first[:avatar_url],
      presence: :none
    }
  end

  defp assignee(_issue), do: nil

  # GitHub prints who opened an issue beside when. An issue whose author is
  # gone still has a history, so it says so rather than showing a blank.
  defp author(%{user: %{} = user}), do: user["login"] || user[:login] || "anonymous"
  defp author(_issue), do: "anonymous"

  defp relative(nil), do: nil

  defp relative(at) do
    at = if is_struct(at, NaiveDateTime), do: DateTime.from_naive!(at, "Etc/UTC"), else: at

    case DateTime.diff(DateTime.utc_now(), at, :second) do
      s when s < 3_600 -> "#{max(div(s, 60), 1)}m"
      s when s < 86_400 -> "#{div(s, 3_600)}h"
      s -> "#{div(s, 86_400)}d"
    end
  end
end
