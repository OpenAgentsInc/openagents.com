defmodule OpenAgentsWeb.ProjectShowLive do
  @moduledoc """
  Renders a simple kanban board for a Project V2.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.Projects
  alias OpenAgents.ProjectItems.ProjectItem

  @statuses ["To Do", "In Progress", "Done"]

  def mount(%{"owner" => owner, "repo" => repo, "number" => number}, _session, socket) do
    project = Projects.get_project_by_number!(String.to_integer(number))
    items = project_items(project.id)
    issue_options = issue_options()

    {:ok,
     socket
     |> assign(:current_scope, nil)
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:project, project)
     |> assign(:items, items)
     |> assign(:issue_options, issue_options)
     |> assign(:status_options, Enum.map(@statuses, &{&1, &1}))
     |> assign(:form, to_form(ProjectItem.changeset(%ProjectItem{}, %{}), as: "item"))}
  end

  def handle_event("add_item", %{"item" => item_params}, socket) do
    project = socket.assigns.project
    number = String.to_integer(item_params["issue_number"])
    status = item_params["status"] || "To Do"

    case Projects.create_project_item(
           %{"issue_number" => number, "values" => %{"Status" => status}},
           project.id
         ) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(:items, project_items(project.id))
         |> assign(:form, to_form(ProjectItem.changeset(%ProjectItem{}, %{}), as: "item"))
         |> put_flash(:info, "Issue added to project")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp project_items(project_id) do
    Projects.list_project_items(project_id)
    |> Enum.map(fn item ->
      issue = Issues.get_issue!(item.issue_id)
      status = get_in(item.values, ["Status"]) || "To Do"
      Map.merge(item, %{issue: issue, status: status})
    end)
  end

  defp issue_options do
    Issues.list_issues(state: "all")
    |> Enum.map(&{"##{&1.number} #{&1.title}", &1.number})
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.repo_header owner={@owner} repo={@repo} active="projects" />

      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">{@project.title}</h1>
        <.link navigate={~p"/#{@owner}/#{@repo}/projects"} class="btn btn-ghost btn-sm">
          Back to projects
        </.link>
      </div>

      <.form
        for={@form}
        id="new-project-item-form"
        phx-submit="add_item"
        class="card bg-base-100 border border-base-300 p-4 mb-6"
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
        <div class="card-actions justify-end mt-2">
          <.button variant="primary">Add to board</.button>
        </div>
      </.form>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4 items-start">
        <%= for status <- @statuses do %>
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body p-3">
              <h3 class="card-title text-sm font-bold mb-2">{status}</h3>
              <div class="space-y-2 min-h-24">
                <%= for item <- @items, item.status == status do %>
                  <div class="card bg-base-100 border border-base-300 shadow-sm p-3">
                    <.link
                      navigate={~p"/#{@owner}/#{@repo}/issues/#{item.issue.number}"}
                      class="link link-primary text-sm font-semibold"
                    >
                      {item.issue.title}
                    </.link>
                    <span class="text-xs text-base-content/50 block">
                      #{item.issue.number}
                    </span>
                    <div class="flex flex-wrap gap-1 mt-2">
                      <%= for label <- item.issue.labels || [] do %>
                        <span
                          class="badge badge-sm"
                          style={"background-color: ##{label["color"]}; color: #000;"}
                        >
                          {label["name"]}
                        </span>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
