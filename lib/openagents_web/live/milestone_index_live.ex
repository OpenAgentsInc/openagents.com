defmodule OpenAgentsWeb.MilestoneIndexLive do
  @moduledoc """
  Renders repository milestones and a form to create them.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.Milestones
  alias OpenAgents.Milestones.Milestone

  def mount(%{"owner" => owner, "repo" => repo}, _session, socket) do
    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:milestones, milestones_with_stats())
     |> assign(:form, to_form(Milestones.change_milestone(%Milestone{})))}
  end

  def handle_event("save", %{"milestone" => milestone_params}, socket) do
    case Milestones.create_milestone(milestone_params) do
      {:ok, _milestone} ->
        {:noreply,
         socket
         |> assign(:milestones, milestones_with_stats())
         |> assign(:form, to_form(Milestones.change_milestone(%Milestone{})))
         |> put_flash(:info, "Milestone created")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("close", %{"id" => id}, socket) do
    milestone = Milestones.get_milestone!(String.to_integer(id))
    {:ok, _} = Milestones.update_milestone(milestone, %{"state" => "closed"})

    {:noreply,
     socket
     |> assign(:milestones, milestones_with_stats())
     |> put_flash(:info, "Milestone closed")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    milestone = Milestones.get_milestone!(String.to_integer(id))
    {:ok, _} = Milestones.delete_milestone(milestone)

    {:noreply,
     socket
     |> assign(:milestones, milestones_with_stats())
     |> put_flash(:info, "Milestone deleted")}
  end

  defp milestones_with_stats do
    all_issues = Issues.list_issues(state: "all")

    Milestones.list_milestones()
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
        class="card bg-base-100 border border-base-300 p-4 mb-6"
      >
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4 items-end">
          <.input field={@form[:title]} label="Title" required />
          <.input field={@form[:due_on]} label="Due on" />
          <.input field={@form[:description]} label="Description" />
        </div>
        <div class="card-actions justify-end mt-2">
          <.button variant="primary">Add milestone</.button>
        </div>
      </.form>

      <%= if @milestones == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="size-5" />
          <span>No milestones yet.</span>
        </div>
      <% else %>
        <div class="space-y-4">
          <%= for milestone <- @milestones do %>
            <div class="card bg-base-100 border border-base-300 p-4">
              <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-2 mb-2">
                <h3 class="text-lg font-semibold">{milestone.title}</h3>
                <div class="flex gap-2">
                  <span class={[
                    "badge badge-sm",
                    milestone.state == "open" && "badge-success",
                    milestone.state == "closed" && "badge-ghost"
                  ]}>
                    {milestone.state}
                  </span>
                  <%= if milestone.due_on do %>
                    <span class="badge badge-ghost badge-sm">Due {milestone.due_on}</span>
                  <% end %>
                </div>
              </div>

              <%= if milestone.description do %>
                <p class="text-sm text-base-content/70 mb-3">
                  {milestone.description}
                </p>
              <% end %>

              <div class="flex items-center gap-4 mb-2">
                <div class="flex-1">
                  <progress
                    class="progress progress-success w-full"
                    value={milestone.progress}
                    max="100"
                  ></progress>
                </div>
                <span class="text-sm font-semibold w-12 text-right">
                  {milestone.progress}%
                </span>
              </div>

              <div class="flex items-center gap-4 text-sm text-base-content/70 mb-3">
                <span>{milestone.open_count} open</span>
                <span>{milestone.closed_count} closed</span>
                <span>{milestone.total_count} total</span>
              </div>

              <div class="card-actions justify-end">
                <%= if milestone.state == "open" do %>
                  <button
                    class="btn btn-ghost btn-sm"
                    phx-click="close"
                    phx-value-id={milestone.id}
                  >
                    Close
                  </button>
                <% end %>
                <button
                  class="btn btn-ghost btn-sm text-error"
                  phx-click="delete"
                  phx-value-id={milestone.id}
                  data-confirm="Delete this milestone?"
                >
                  Delete
                </button>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
