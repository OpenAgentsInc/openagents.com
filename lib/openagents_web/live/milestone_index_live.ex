defmodule OpenAgentsWeb.MilestoneIndexLive do
  @moduledoc """
  Renders repository milestones and a form to create them.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.Milestones
  alias OpenAgents.Milestones.Milestone
  alias OpenAgents.Repositories

  def mount(%{"owner" => owner, "repo" => repo}, _session, socket) do
    repository = Repositories.get_writable_by_path!(owner, repo, socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> assign(:milestones, milestones_with_stats(repository))
     |> assign(:form, to_form(Milestones.change_milestone(%Milestone{})))}
  end

  def handle_event("save", %{"milestone" => milestone_params}, socket) do
    case Milestones.create_milestone(socket.assigns.repository, milestone_params) do
      {:ok, _milestone} ->
        {:noreply,
         socket
         |> assign(:milestones, milestones_with_stats(socket.assigns.repository))
         |> assign(:form, to_form(Milestones.change_milestone(%Milestone{})))
         |> put_flash(:info, "Milestone created")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("close", %{"id" => id}, socket) do
    milestone = Milestones.get_milestone!(socket.assigns.repository, String.to_integer(id))
    {:ok, _} = Milestones.update_milestone(milestone, %{"state" => "closed"})

    {:noreply,
     socket
     |> assign(:milestones, milestones_with_stats(socket.assigns.repository))
     |> put_flash(:info, "Milestone closed")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    milestone = Milestones.get_milestone!(socket.assigns.repository, String.to_integer(id))
    {:ok, _} = Milestones.delete_milestone(milestone)

    {:noreply,
     socket
     |> assign(:milestones, milestones_with_stats(socket.assigns.repository))
     |> put_flash(:info, "Milestone deleted")}
  end

  defp milestones_with_stats(repository) do
    all_issues = Issues.list_issues(repository, state: "all")

    Milestones.list_milestones(repository)
    |> Enum.map(fn milestone ->
      open =
        Enum.count(all_issues, fn i ->
          i.milestone && i.milestone["number"] == milestone.number && i.state == "open"
        end)

      closed =
        Enum.count(all_issues, fn i ->
          i.milestone && i.milestone["number"] == milestone.number && i.state == "closed"
        end)

      total = open + closed
      progress = if total > 0, do: div(closed * 100, total), else: 0

      Map.merge(milestone, %{
        open_count: open,
        closed_count: closed,
        total_count: total,
        progress: progress
      })
    end)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">Milestones</h1>
      </div>

      <.form
        for={@form}
        id="new-milestone-form"
        phx-submit="save"
        class="card !mx-0 !mt-0 mb-6"
      >
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4 items-end">
          <.input field={@form[:title]} label="Title" required />
          <.input field={@form[:due_on]} label="Due on" />
          <.input field={@form[:description]} label="Description" />
        </div>
        <footer class="flex justify-end mt-2">
          <.button type="submit" variant={:primary}>Add milestone</.button>
        </footer>
      </.form>

      <%= if @milestones == [] do %>
        <div class="alert" data-variant="info" role="status">
          <.icon name="info-circle" class="size-5" />
          <section>No milestones yet.</section>
        </div>
      <% else %>
        <div class="space-y-4">
          <%= for milestone <- @milestones do %>
            <div class="card !m-0">
              <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-2 mb-2">
                <h3 class="text-lg font-semibold">{milestone.title}</h3>
                <div class="flex gap-2">
                  <span
                    class="badge"
                    data-variant={if milestone.state == "open", do: "success", else: "dim"}
                  >
                    {milestone.state}
                  </span>
                  <%= if milestone.due_on do %>
                    <span class="badge" data-variant="dim">Due {milestone.due_on}</span>
                  <% end %>
                </div>
              </div>

              <%= if milestone.description do %>
                <p class="text-sm text-muted-foreground mb-3">
                  {milestone.description}
                </p>
              <% end %>

              <div class="flex items-center gap-4 mb-2">
                <%!-- A meter, not task progress: the value is a measured
                ratio of closed to total, so `<progress>`'s indeterminate state
                never applies. Drawn from the surface rungs rather than a
                component variant, since the style pack has no bar. --%>
                <div
                  class="flex-1 h-2 rounded-full bg-muted overflow-hidden"
                  role="progressbar"
                  aria-valuenow={milestone.progress}
                  aria-valuemin="0"
                  aria-valuemax="100"
                  aria-label={"#{milestone.title} progress"}
                >
                  <div class="h-full bg-success" style={"width: #{milestone.progress}%;"}></div>
                </div>
                <span class="text-sm font-semibold w-12 text-right">
                  {milestone.progress}%
                </span>
              </div>

              <div class="flex items-center gap-4 text-sm text-muted-foreground mb-3">
                <span>{milestone.open_count} open</span>
                <span>{milestone.closed_count} closed</span>
                <span>{milestone.total_count} total</span>
              </div>

              <footer class="flex justify-end gap-2">
                <%= if milestone.state == "open" do %>
                  <button
                    class="btn"
                    data-variant="ghost"
                    data-size="sm"
                    phx-click="close"
                    phx-value-id={milestone.id}
                  >
                    Close
                  </button>
                <% end %>
                <button
                  class="btn"
                  data-variant="ghost"
                  data-size="sm"
                  data-tone="danger"
                  phx-click="delete"
                  phx-value-id={milestone.id}
                  data-confirm="Delete this milestone?"
                >
                  Delete
                </button>
              </footer>
            </div>
          <% end %>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
