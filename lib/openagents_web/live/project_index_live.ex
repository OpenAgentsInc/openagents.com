defmodule OpenAgentsWeb.ProjectIndexLive do
  @moduledoc """
  Renders a list of Projects V2 for a repository.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Projects
  alias OpenAgents.Projects.Project

  def mount(%{"owner" => owner, "repo" => repo}, _session, socket) do
    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:projects, filter_projects(owner))
     |> assign(:form, to_form(Projects.change_project(%Project{})))}
  end

  def handle_event("save", %{"project" => project_params}, socket) do
    owner = socket.assigns.owner
    params = Map.put(project_params, "owner", owner)

    case Projects.create_project(params) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> assign(:projects, filter_projects(owner))
         |> assign(:form, to_form(Projects.change_project(%Project{})))
         |> put_flash(:info, "Project created")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    project = Projects.get_project!(String.to_integer(id))
    {:ok, _} = Projects.delete_project(project)

    {:noreply,
     socket
     |> assign(:projects, filter_projects(socket.assigns.owner))
     |> put_flash(:info, "Project deleted")}
  end

  defp filter_projects(owner) do
    Projects.list_projects()
    |> Enum.filter(&(&1.owner == owner))
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.repo_header owner={@owner} repo={@repo} active="projects" />

      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">Projects</h1>
      </div>

      <.form
        for={@form}
        id="new-project-form"
        phx-submit="save"
        class="card bg-base-100 border border-base-300 p-4 mb-6"
      >
        <.input field={@form[:title]} label="Title" required />
        <div class="card-actions justify-end mt-2">
          <.button variant="primary">Add project</.button>
        </div>
      </.form>

      <%= if @projects == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="size-5" />
          <span>No projects yet.</span>
        </div>
      <% else %>
        <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          <%= for project <- @projects do %>
            <div class="card bg-base-100 border border-base-300">
              <div class="card-body">
                <h3 class="card-title">
                  <.link
                    navigate={~p"/#{@owner}/#{@repo}/projects/#{project.number}"}
                    class="link link-primary"
                  >
                    {project.title}
                  </.link>
                </h3>
                <p class="text-sm text-base-content/70">
                  {project.state}
                </p>
                <div class="card-actions justify-end">
                  <.link
                    navigate={~p"/#{@owner}/#{@repo}/projects/#{project.number}"}
                    class="btn btn-sm btn-ghost"
                  >
                    View
                  </.link>
                  <button
                    class="btn btn-ghost btn-sm text-error"
                    phx-click="delete"
                    phx-value-id={project.id}
                    data-confirm="Delete this project?"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
