defmodule OpenAgentsWeb.AssigneeIndexLive do
  @moduledoc """
  Renders assignees derived from existing issue data.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.Repositories

  def mount(%{"owner" => owner, "repo" => repo}, _session, socket) do
    repository = Repositories.get_writable_by_path!(owner, repo, socket.assigns.current_user)

    assignees =
      Issues.list_issues(repository, state: "all")
      |> Enum.flat_map(&(&1.assignees || []))
      |> Enum.frequencies_by(& &1["login"])
      |> Enum.sort_by(fn {_, count} -> -count end)

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> assign(:assignees, assignees)}
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
