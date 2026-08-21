defmodule OpenAgentsWeb.IssueIndexLive do
  @moduledoc """
  Lists issues for a repository.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgentsWeb.UI.Circle
  alias OpenAgents.Repositories

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :current_scope, socket.assigns[:current_scope])}
  end

  def handle_params(%{"owner" => owner, "repo" => repo} = params, _url, socket) do
    state = params["state"] || "open"
    repository = Repositories.get_writable_by_path!(owner, repo, socket.assigns.current_user)

    socket =
      socket
      |> assign(:owner, owner)
      |> assign(:repo, repo)
      |> assign(:repository, repository)
      |> assign(:state, state)
      |> assign(:assignable, Repositories.list_assignable_users(repository))
      |> load()

    {:noreply, socket}
  end

  # The row's own controls, which is what Circle has that a static list does
  # not. Only state and assignee: they are the two facts worth changing without
  # opening the issue, and labels and milestone need option lists longer than a
  # row has room to explain. Both live in the rail on the issue page instead.
  def handle_event("set_state", %{"id" => id, "state" => "open"}, socket),
    do: write(socket, id, %{"state" => "open", "state_reason" => nil})

  def handle_event("set_state", %{"id" => id, "state" => "closed"} = params, socket),
    do: write(socket, id, %{"state" => "closed", "state_reason" => params["reason"]})

  def handle_event("toggle_assignee", %{"id" => id, "login" => login}, socket) do
    issue = issue!(socket, id)

    {:ok, _updated} =
      if Enum.any?(issue.assignees || [], &(&1["login"] == login)) do
        Issues.remove_assignees(issue, [login])
      else
        Issues.add_assignees(issue, [login])
      end

    {:noreply, load(socket)}
  end

  defp write(socket, id, attrs) do
    {:ok, _updated} = Issues.update_issue(issue!(socket, id), attrs, socket.assigns.current_user)
    {:noreply, load(socket)}
  end

  # `JS.push` sends the id as a number; a `phx-value-` attribute would send a
  # string. The handler takes whichever arrives.
  defp issue!(socket, id) when is_integer(id),
    do: Issues.get_issue!(socket.assigns.repository, id)

  defp issue!(socket, id) when is_binary(id),
    do: Issues.get_issue!(socket.assigns.repository, String.to_integer(id))

  # Reloading rather than patching one row: closing an issue while the Open tab
  # is showing has to remove it from the list and change both tab counts, and a
  # row that stays visible after being closed is worse than a reload.
  defp load(socket) do
    repository = socket.assigns.repository
    issues = Issues.list_issues(repository, state: socket.assigns.state)

    socket
    |> assign(:open_count, length(Issues.list_issues(repository, state: "open")))
    |> assign(:closed_count, length(Issues.list_issues(repository, state: "closed")))
    |> assign(:issues_count, length(issues))
    |> stream(:issues, issues, reset: true)
  end

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
              patch={~p"/#{@owner}/#{@repo}/issues?state=open"}
              selected={@state == "open"}
            />
            <:tab
              label={"#{@closed_count} Closed"}
              patch={~p"/#{@owner}/#{@repo}/issues?state=closed"}
              selected={@state == "closed"}
            />
          </Circle.view_tabs>
        </:leading>

        <:actions>
          <.link
            navigate={~p"/#{@owner}/#{@repo}/labels"}
            class="btn"
            data-variant="ghost"
            data-size="sm"
          >
            <.icon name="tag" /> Labels
          </.link>
          <.link
            navigate={~p"/#{@owner}/#{@repo}/milestones"}
            class="btn"
            data-variant="ghost"
            data-size="sm"
          >
            <.icon name="flag" /> Milestones
          </.link>
          <.link
            navigate={~p"/#{@owner}/#{@repo}/issues/new"}
            class="btn"
            data-variant="primary"
            data-size="sm"
          >
            New issue
          </.link>
        </:actions>
      </Circle.issue_toolbar>

      <.empty
        :if={@issues_count == 0}
        id="issues-empty"
        title={"No #{@state} issues"}
      >
        Issues will show up here once they are created.
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
          <:state>
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
          <:people>
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
    </Layouts.app>
    """
  end

  # The row's own state cell is a control now, so the static category and label
  # it would otherwise draw come from `Circle.issue_state/1` instead. They stay
  # as the row's defaults for a caller with nowhere to send a change.
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
