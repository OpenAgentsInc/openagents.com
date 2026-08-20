defmodule OpenAgentsWeb.ProjectIndexLive do
  @moduledoc """
  Renders a list of Projects V2 for a repository.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Projects
  alias OpenAgents.Projects.Project
  alias OpenAgents.Repositories

  def mount(%{"owner" => owner, "repo" => repo}, _session, socket) do
    repository = Repositories.get_writable_by_path!(owner, repo, socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> assign(:projects, Projects.list_projects(repository))
     |> assign(:form, to_form(Projects.change_project(%Project{})))}
  end

  def handle_event("save", %{"project" => project_params}, socket) do
    case Projects.create_project(
           socket.assigns.repository,
           project_params,
           socket.assigns.current_user
         ) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> assign(:projects, Projects.list_projects(socket.assigns.repository))
         |> assign(:form, to_form(Projects.change_project(%Project{})))
         |> put_flash(:info, "Project created")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    project = Projects.get_project!(socket.assigns.repository, String.to_integer(id))
    {:ok, _} = Projects.delete_project(project)

    {:noreply,
     socket
     |> assign(:projects, Projects.list_projects(socket.assigns.repository))
     |> put_flash(:info, "Project deleted")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">Projects</h1>
      </div>

      <.form
        for={@form}
        id="new-project-form"
        phx-submit="save"
        class="card !mx-0 !mt-0 mb-6"
      >
        <.input field={@form[:title]} label="Title" required />
        <footer class="flex justify-end mt-2">
          <.button variant={:primary}>Add project</.button>
        </footer>
      </.form>

      <%= if @projects == [] do %>
        <div class="alert" data-variant="info" role="status">
          <.icon name="info-circle" class="size-5" />
          <section>No projects yet.</section>
        </div>
      <% else %>
        <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          <%= for project <- @projects do %>
            <article class="card !m-0">
              <header>
                <h3 class="card-title">
                  <.link
                    navigate={~p"/#{@owner}/#{@repo}/projects/#{project.number}"}
                    class="btn px-0"
                    data-variant="link"
                  >
                    {project.title}
                  </.link>
                </h3>
                <p>{project.state}</p>
              </header>
              <footer class="flex justify-end gap-2 mt-4">
                <.link
                  navigate={~p"/#{@owner}/#{@repo}/projects/#{project.number}"}
                  class="btn"
                  data-variant="ghost"
                  data-size="sm"
                >
                  View
                </.link>
                <button
                  class="btn"
                  data-variant="ghost"
                  data-size="sm"
                  data-tone="danger"
                  phx-click="delete"
                  phx-value-id={project.id}
                  data-confirm="Delete this project?"
                >
                  Delete
                </button>
              </footer>
            </article>
          <% end %>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
