defmodule OpenAgentsWeb.LabelIndexLive do
  @moduledoc """
  Renders repository labels and a form to create them.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Labels
  alias OpenAgents.Labels.Label

  def mount(%{"owner" => owner, "repo" => repo}, _session, socket) do
    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:labels, Labels.list_labels())
     |> assign(:form, to_form(Labels.change_label(%Label{})))}
  end

  def handle_event("save", %{"label" => label_params}, socket) do
    case Labels.create_label(label_params) do
      {:ok, _label} ->
        {:noreply,
         socket
         |> assign(:labels, Labels.list_labels())
         |> assign(:form, to_form(Labels.change_label(%Label{})))
         |> put_flash(:info, "Label created")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    label = Labels.get_label!(String.to_integer(id))
    {:ok, _} = Labels.delete_label(label)

    {:noreply,
     socket
     |> assign(:labels, Labels.list_labels())
     |> put_flash(:info, "Label deleted")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.repo_header owner={@owner} repo={@repo} active="labels" />

      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">Labels</h1>
      </div>

      <.form
        for={@form}
        id="new-label-form"
        phx-submit="save"
        class="card bg-base-100 border border-base-300 p-4 mb-6"
      >
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4 items-end">
          <.input field={@form[:name]} label="Name" required />
          <.input field={@form[:color]} label="Color" required />
          <.input field={@form[:description]} label="Description" />
        </div>
        <div class="card-actions justify-end mt-2">
          <.button variant="primary">Add label</.button>
        </div>
      </.form>

      <%= if @labels == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="size-5" />
          <span>No labels yet.</span>
        </div>
      <% else %>
        <.table id="labels" rows={@labels}>
          <:col :let={label} label="Label">
            <span class="badge badge-md" style={"background-color: ##{label.color}; color: #000;"}>
              {label.name}
            </span>
          </:col>
          <:col :let={label} label="Description">{label.description || "—"}</:col>
          <:col :let={label} label="">
            <button
              class="btn btn-ghost btn-sm text-error"
              phx-click="delete"
              phx-value-id={label.id}
              data-confirm="Delete this label?"
            >
              Delete
            </button>
          </:col>
        </.table>
      <% end %>
    </Layouts.app>
    """
  end
end
