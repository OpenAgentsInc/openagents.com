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
    repository = visible_repository!(owner, repo, socket.assigns.current_user)
    can_write = Repositories.writable?(repository, socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> assign(:can_write, can_write)
     |> assign(:projects, Projects.list_projects(repository))
     |> assign(:form, to_form(Projects.change_project(repository, %Project{}, %{})))}
  end

  def handle_event("save", %{"project" => project_params}, socket) do
    socket = refresh_authority(socket)

    if socket.assigns.can_write do
      case Projects.create_project(
             socket.assigns.repository,
             project_params,
             socket.assigns.current_user
           ) do
        {:ok, _project} ->
          {:noreply,
           socket
           |> assign(:projects, Projects.list_projects(socket.assigns.repository))
           |> assign(
             :form,
             to_form(Projects.change_project(socket.assigns.repository, %Project{}, %{}))
           )
           |> put_flash(:info, "Project created")}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Only repository members can create projects.")}
    end
  end

  # Projects V2 has `state`, so closing one is a GitHub field rather than an
  # invented concept -- and it is the only property of a project this schema
  # carries that is worth changing without opening the board.
  def handle_event("set_state", %{"id" => id, "state" => state}, socket) do
    socket = refresh_authority(socket)

    if socket.assigns.can_write do
      project = Projects.get_project!(socket.assigns.repository, id)
      {:ok, _updated} = Projects.update_project(project, %{"state" => state})

      {:noreply, assign(socket, :projects, Projects.list_projects(socket.assigns.repository))}
    else
      {:noreply, put_flash(socket, :error, "Only repository members can change project state.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    socket = refresh_authority(socket)

    if socket.assigns.can_write do
      project = Projects.get_project!(socket.assigns.repository, String.to_integer(id))
      {:ok, _} = Projects.delete_project(project)

      {:noreply,
       socket
       |> assign(:projects, Projects.list_projects(socket.assigns.repository))
       |> put_flash(:info, "Project deleted")}
    else
      {:noreply, put_flash(socket, :error, "Only repository members can delete projects.")}
    end
  end

  defp refresh_authority(socket) do
    assign(
      socket,
      :can_write,
      Repositories.writable?(socket.assigns.repository, socket.assigns.current_user)
    )
  end

  defp visible_repository!(owner, repo, user) do
    Repositories.get_visible_by_path!(owner, repo, user)
  rescue
    Ecto.NoResultsError ->
      raise OpenAgentsWeb.PublicNotFoundError, message: "repository not found"
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Projects"
      wide
    >
      <.form
        :if={@can_write}
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

      <div :if={@projects == []} id="projects-empty" class="alert" data-variant="info" role="status">
        <.icon name="info-circle" class="size-5" />
        <section>No projects yet.</section>
      </div>

      <div :if={@projects != []} id="projects" class="project-index">
        <div :for={project <- @projects} class="project-index__row">
          <Circle.project_row
            name={project.title}
            navigate={~p"/#{@owner}/#{@repo}/projects/#{project.number}"}
            status_category={if project.state == "closed", do: :completed, else: :unstarted}
            status_label={String.capitalize(project.state)}
          >
            <:state :if={@can_write}>
              <Circle.field_menu
                id={"project-state-#{project.id}"}
                label={"Change the state of #{project.title}"}
                align={:end}
              >
                <:trigger><Circle.issue_state state={project.state} /></:trigger>
                <Circle.field_menu_item
                  :for={state <- ~w(open closed)}
                  label={String.capitalize(state)}
                  mode={:choice}
                  selected={project.state == state}
                  closes={"project-state-#{project.id}"}
                  on_select={JS.push("set_state", value: %{id: project.id, state: state})}
                >
                  <:glyph><Circle.issue_state state={state} /></:glyph>
                </Circle.field_menu_item>
              </Circle.field_menu>
            </:state>
          </Circle.project_row>
          <%!-- Deletion stays a control of its own rather than something the
          row grew: the row is a link to a board, and a destructive action
          inside a link target is how people delete things by accident. --%>
          <button
            :if={@can_write}
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
