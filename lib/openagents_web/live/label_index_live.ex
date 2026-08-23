defmodule OpenAgentsWeb.LabelIndexLive do
  @moduledoc """
  Renders repository labels and a form to create them.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Labels
  alias OpenAgents.Labels.Label
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
     |> assign(:labels, Labels.list_labels(repository))
     |> assign(:form, to_form(Labels.change_label(%Label{})))}
  end

  def handle_event("save", %{"label" => label_params}, socket) do
    socket = refresh_authority(socket)

    if socket.assigns.can_write do
      case Labels.create_label(
             socket.assigns.repository,
             label_params,
             socket.assigns.current_user
           ) do
        {:ok, _label} ->
          {:noreply,
           socket
           |> assign(:labels, Labels.list_labels(socket.assigns.repository))
           |> assign(:form, to_form(Labels.change_label(%Label{})))
           |> put_flash(:info, "Label created")}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Only repository members can create labels.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    socket = refresh_authority(socket)

    if socket.assigns.can_write do
      label = Labels.get_label!(socket.assigns.repository, String.to_integer(id))
      {:ok, _} = Labels.delete_label(label)

      {:noreply,
       socket
       |> assign(:labels, Labels.list_labels(socket.assigns.repository))
       |> put_flash(:info, "Label deleted")}
    else
      {:noreply, put_flash(socket, :error, "Only repository members can delete labels.")}
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
    >
      <div class="flex items-center justify-between mb-4">
        <h1 id="labels-title" class="text-2xl font-bold">Labels</h1>
      </div>

      <.form
        :if={@can_write}
        for={@form}
        id="new-label-form"
        phx-submit="save"
        class="card !mx-0 !mt-0 mb-6"
      >
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4 items-end">
          <.input field={@form[:name]} label="Name" required />
          <.input field={@form[:color]} label="Color" required />
          <.input field={@form[:description]} label="Description" />
        </div>
        <footer class="flex justify-end mt-2">
          <.button type="submit" variant={:primary}>Add label</.button>
        </footer>
      </.form>

      <%= if @labels == [] do %>
        <div id="labels-empty" class="alert" data-variant="info" role="status">
          <.icon name="info-circle" class="size-5" />
          <section>No labels yet.</section>
        </div>
      <% else %>
        <.table id="labels" rows={@labels}>
          <:col :let={label} label="Label">
            <span
              class="badge rounded-full px-2 py-0.5"
              style={"background-color: ##{label.color}; color: #000;"}
            >
              {label.name}
            </span>
          </:col>
          <:col :let={label} label="Description">{label.description || "—"}</:col>
          <:col :let={label} label="">
            <button
              :if={@can_write}
              class="btn"
              data-variant="ghost"
              data-size="sm"
              data-tone="danger"
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
