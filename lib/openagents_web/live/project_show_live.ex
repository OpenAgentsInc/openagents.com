defmodule OpenAgentsWeb.ProjectShowLive do
  @moduledoc """
  Renders a simple kanban board for a Project V2.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.Projects
  alias OpenAgents.ProjectItems.ProjectItem
  alias OpenAgents.Repositories

  @statuses ["To Do", "In Progress", "Done"]

  def mount(%{"owner" => owner, "repo" => repo, "number" => number}, _session, socket) do
    repository = Repositories.get_writable_by_path!(owner, repo, socket.assigns.current_user)
    project = Projects.get_project_by_number!(repository, String.to_integer(number))
    items = project_items(repository, project)
    issue_options = issue_options(repository)

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> assign(:project, project)
     |> assign(:items, items)
     |> assign(:issue_options, issue_options)
     # The board columns are read as `@statuses` inside ~H, where `@` means
     # `assigns.statuses`, not the module attribute. Without this assign every
     # render raised KeyError and the route was unreachable.
     |> assign(:statuses, @statuses)
     |> assign(:status_options, Enum.map(@statuses, &{&1, &1}))
     |> assign(:form, to_form(ProjectItem.changeset(%ProjectItem{}, %{}), as: "item"))}
  end

  def handle_event("add_item", %{"item" => item_params}, socket) do
    project = socket.assigns.project
    number = String.to_integer(item_params["issue_number"])
    status = item_params["status"] || "To Do"

    case Projects.create_project_item(
           %{"issue_number" => number, "values" => %{"Status" => status}},
           project
         ) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(:items, project_items(socket.assigns.repository, project))
         |> assign(:form, to_form(ProjectItem.changeset(%ProjectItem{}, %{}), as: "item"))
         |> put_flash(:info, "Issue added to project")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp project_items(repository, project) do
    Projects.list_project_items(project)
    |> Enum.map(fn item ->
      issue = Issues.get_issue!(repository, item.issue_id)
      status = get_in(item.values, ["Status"]) || "To Do"
      Map.merge(item, %{issue: issue, status: status})
    end)
  end

  defp issue_options(repository) do
    Issues.list_issues(repository, state: "all")
    |> Enum.map(&{"##{&1.number} #{&1.title}", &1.number})
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">{@project.title}</h1>
        <.link
          navigate={~p"/#{@owner}/#{@repo}/projects"}
          class="btn"
          data-variant="ghost"
          data-size="sm"
        >
          Back to projects
        </.link>
      </div>

      <.form
        for={@form}
        id="new-project-item-form"
        phx-submit="add_item"
        class="card !mx-0 !mt-0 mb-6"
      >
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4 items-end">
          <.input
            field={@form[:issue_number]}
            type="select"
            label="Issue"
            options={@issue_options}
            prompt="Select an issue"
            required
          />
          <.input
            field={@form[:status]}
            type="select"
            label="Status"
            options={@status_options}
            required
          />
        </div>
        <footer class="flex justify-end mt-2">
          <.button type="submit" variant={:primary}>Add to board</.button>
        </footer>
      </.form>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4 items-start">
        <%= for status <- @statuses do %>
          <section class="card !m-0 !p-3">
            <header class="mb-2">
              <h3 class="card-title !text-sm">{status}</h3>
            </header>
            <div class="space-y-2 min-h-24">
              <%= for item <- @items, item.status == status do %>
                <article class="card !m-0 !p-3">
                  <.link
                    navigate={~p"/#{@owner}/#{@repo}/issues/#{item.issue.number}"}
                    class="btn px-0 text-sm font-semibold"
                    data-variant="link"
                  >
                    {item.issue.title}
                  </.link>
                  <span class="text-xs text-muted-foreground block">
                    #{item.issue.number}
                  </span>
                  <div class="flex flex-wrap gap-1 mt-2">
                    <%= for label <- item.issue.labels || [] do %>
                      <span
                        class="badge rounded-full px-2 py-0.5"
                        style={"background-color: ##{label["color"]}; color: #000;"}
                      >
                        {label["name"]}
                      </span>
                    <% end %>
                  </div>
                </article>
              <% end %>
            </div>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
