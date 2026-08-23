defmodule OpenAgentsWeb.AssigneeIndexLive do
  @moduledoc """
  Renders assignees derived from existing issue data.

  The page is a frequency aggregate over issues, so it moves whenever the
  repository's issues do. It hears that on the issue topic and re-reads
  through the same writable-repository check it mounted under; the message
  carries a repository id and nothing else.

  The aggregate is grouped in Postgres rather than in memory. Loading every
  issue in a repository to count logins is the read `93c3383` removed from the
  homepage, and a page that re-read it per write would pay it far more often
  than a page that only ever read it once.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.LiveRefresh

  def mount(%{"owner" => owner, "repo" => repo}, _session, socket) do
    repository = Repositories.get_writable_by_path!(owner, repo, socket.assigns.current_user)

    if connected?(socket), do: Repositories.subscribe_issues(repository.id)

    {:ok,
     socket
     |> LiveRefresh.init()
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> refresh_panel(:assignees)}
  end

  def handle_info({:issues_changed, repository_id}, socket) do
    if repository_id == socket.assigns.repository.id,
      do: {:noreply, LiveRefresh.mark_stale(socket, :assignees, &refresh_panel/2)},
      else: {:noreply, socket}
  end

  def handle_info(:live_refresh, socket),
    do: {:noreply, LiveRefresh.run(socket, &refresh_panel/2)}

  # Re-read through the same check the mount made: a viewer whose write access
  # was revoked while the page was open stops being handed its rows.
  defp refresh_panel(socket, :assignees) do
    case Repositories.get_visible_repository(
           socket.assigns.repository.id,
           socket.assigns.current_user
         ) do
      nil ->
        assign(socket, :assignees, [])

      repository ->
        if Repositories.writable?(repository, socket.assigns.current_user),
          do: assign(socket, :assignees, Issues.count_issues_by_assignee(repository)),
          else: assign(socket, :assignees, [])
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <h1 class="text-2xl font-bold mb-4">Assignees</h1>

      <%= if @assignees == [] do %>
        <div class="alert" data-variant="info" role="status">
          <.icon name="info-circle" class="size-5" />
          <section>No assignees have been assigned to issues yet.</section>
        </div>
      <% else %>
        <.table id="assignees" rows={@assignees}>
          <:col :let={{login, _count}} label="Assignee">
            <div class="flex items-center gap-2">
              <span class="avatar size-8 font-semibold">
                <span>{login |> String.first() |> String.upcase()}</span>
              </span>
              <span class="font-semibold">{login}</span>
            </div>
          </:col>
          <:col :let={{_login, count}} label="Assigned issues">{count}</:col>
        </.table>
      <% end %>
    </Layouts.app>
    """
  end
end
