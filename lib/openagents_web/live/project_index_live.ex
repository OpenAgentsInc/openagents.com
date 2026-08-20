defmodule OpenAgentsWeb.ProjectIndexLive do
  @moduledoc """
  Renders a list of Projects V2 for a repository.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Projects
  alias OpenAgentsWeb.UI.Circle
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
    <Layouts.app flash={@flash} current_scope={@current_scope} title="Projects" wide>
      <.form
        for={@form}
        id="new-project-form"
        phx-submit="save"
        class="card !mx-0 !mt-0 mb-6"
      >
        <.input field={@form[:title]} label="Title" required />
        <footer class="flex justify-end mt-2">
          <.button type="submit" variant={:primary}>Add project</.button>
        </footer>
      </.form>

      <div :if={@projects == []} class="alert" data-variant="info" role="status">
        <.icon name="info-circle" class="size-5" />
        <section>No projects yet.</section>
      </div>

      <div :if={@projects != []} class="project-index">
        <div :for={project <- @projects} class="project-index__row">
          <Circle.project_row
            name={project.title}
            navigate={~p"/#{@owner}/#{@repo}/projects/#{project.number}"}
            status_category={if project.state == "closed", do: :completed, else: :unstarted}
            status_label={String.capitalize(project.state)}
          />
          <%!-- Deletion stays a control of its own rather than something the
          row grew: the row is a link to a board, and a destructive action
          inside a link target is how people delete things by accident. --%>
          <button
            class="btn project-index__delete"
            data-variant="ghost"
            data-size="sm"
            data-tone="danger"
            phx-click="delete"
            phx-value-id={project.id}
            data-confirm="Delete this project?"
          >
            Delete
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
