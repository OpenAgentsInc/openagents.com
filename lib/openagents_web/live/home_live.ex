defmodule OpenAgentsWeb.HomeLive do
  @moduledoc """
  Placeholder homepage with a hero and a list of repositories.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Projects

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_scope, nil)
     |> assign(:projects, Projects.list_projects())}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="hero bg-base-200 rounded-box p-10 mb-8">
        <div class="hero-content text-center">
          <div class="max-w-md">
            <h1 class="text-5xl font-bold">OpenAgents</h1>
            <p class="py-6">
              The agent forge. Track issues, projects, and milestones for your repositories.
            </p>
            <.button navigate={~p"/OpenAgents/openagents/issues/new"} variant="primary">
              Create new issue
            </.button>
          </div>
        </div>
      </div>

      <h2 class="text-2xl font-bold mb-4">Repositories</h2>

      <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        <%= for project <- @projects do %>
          <div class="card bg-base-100 shadow-sm border border-base-300">
            <div class="card-body">
              <h3 class="card-title text-lg">
                <.link
                  navigate={~p"/#{project.owner}/#{project.title}/issues"}
                  class="link link-primary"
                >
                  {project.owner}/{project.title}
                </.link>
              </h3>
              <p class="text-sm text-base-content/70">
                OpenAgents repository placeholder
              </p>
              <div class="card-actions justify-end">
                <.link
                  navigate={~p"/#{project.owner}/#{project.title}/issues"}
                  class="btn btn-sm btn-ghost"
                >
                  Issues
                </.link>
                <.link
                  navigate={~p"/#{project.owner}/#{project.title}/projects"}
                  class="btn btn-sm btn-ghost"
                >
                  Projects
                </.link>
              </div>
            </div>
          </div>
        <% end %>
      </div>

      <%= if @projects == [] do %>
        <div class="alert alert-info mt-8">
          <.icon name="hero-information-circle" class="size-5" />
          <span>No repositories yet. Add a project to see it here.</span>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
