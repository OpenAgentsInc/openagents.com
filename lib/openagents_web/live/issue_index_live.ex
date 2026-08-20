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
    issues = Issues.list_issues(repository, state: state)
    open_count = Issues.list_issues(repository, state: "open") |> length()
    closed_count = Issues.list_issues(repository, state: "closed") |> length()

    socket =
      socket
      |> assign(:owner, owner)
      |> assign(:repo, repo)
      |> assign(:repository, repository)
      |> assign(:state, state)
      |> assign(:open_count, open_count)
      |> assign(:closed_count, closed_count)
      |> assign(:issues_count, length(issues))
      |> stream(:issues, issues, reset: true)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} title="Issues" wide>
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
        />
      </div>
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
