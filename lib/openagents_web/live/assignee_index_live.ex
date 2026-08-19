defmodule OpenAgentsWeb.AssigneeIndexLive do
  @moduledoc """
  Renders assignees derived from existing issue data.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues

  def mount(%{"owner" => owner, "repo" => repo}, _session, socket) do
    assignees =
      Issues.list_issues(state: "all")
      |> Enum.flat_map(&(&1.assignees || []))
      |> Enum.frequencies_by(& &1["login"])
      |> Enum.sort_by(fn {_, count} -> -count end)

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:assignees, assignees)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.repo_header owner={@owner} repo={@repo} active="issues" />

      <h1 class="text-2xl font-bold mb-4">Assignees</h1>

      <%= if @assignees == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="size-5" />
          <span>No assignees have been assigned to issues yet.</span>
        </div>
      <% else %>
        <.table id="assignees" rows={@assignees}>
          <:col :let={{login, _count}} label="Assignee">
            <div class="flex items-center gap-2">
              <div class="avatar avatar-placeholder">
                <div class="bg-neutral text-neutral-content w-8 h-8 rounded-full flex items-center justify-center text-sm font-semibold">
                  {login |> String.first() |> String.upcase()}
                </div>
              </div>
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
