defmodule OpenAgentsWeb.ProjectShowLive do
  @moduledoc """
  One project: its description, its board, and its discussion.

  The page answers three questions in that order — why the project exists, what
  is on it, and what was decided about it — because a board alone carries no
  context and the context is what a reader arriving mid-effort is missing.

  Two structural decisions:

    * **Reading is the default state.** The description renders as prose and
      moves behind **Edit description** for members with write access, so the
      page describes the project rather than being a form that shows one.

    * **The discussion is paginated and separate.** A long-lived project
      accumulates decisions without bound, so the notes are read one page at a
      time through `OpenAgents.Projects.list_project_notes_page/2` rather than
      embedded in the project. Discussion notes and the immutable activity
      record interleave in one feed, because their order relative to each other
      is most of the answer.

  Authority is the project's repository. Anyone who can see the repository can
  read the board and its notes; writing anything needs write access, and
  deleting a note needs authorship.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.Markdown
  alias OpenAgents.Projects
  alias OpenAgents.Projects.PromiseRegistry
  alias OpenAgents.ProjectItems.ProjectItem
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.UI.Circle

  @statuses ["To Do", "In Progress", "Done"]

  def mount(%{"owner" => owner, "repo" => repo, "number" => number}, _session, socket) do
    user = socket.assigns.current_user
    repository = visible_repository!(owner, repo, user)
    project = Projects.get_project_by_number!(repository, String.to_integer(number))
    can_write = Repositories.writable?(repository, user)

    if connected?(socket), do: Repositories.subscribe_projects(repository.id)
    promise_context = PromiseRegistry.context(project)
    items = project_items(project, socket.assigns.current_user, promise_context)
    promise_registry? = promise_context.registry?
    issue_options = issue_options(repository)

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> assign(:project, project)
     |> assign(:can_write, can_write)
     |> assign(:items, items)
     |> assign(:promise_context, promise_context)
     |> assign(:promise_registry?, promise_registry?)
     |> assign(:issue_options, issue_options)
     # The board columns are read as `@statuses` inside ~H, where `@` means
     # `assigns.statuses`, not the module attribute. Without this assign every
     # render raised KeyError and the route was unreachable.
     |> assign(:statuses, @statuses)
     |> assign(:status_options, Enum.map(@statuses, &{&1, &1}))
     |> assign(:editing_description?, false)
     |> assign(:description_form, description_form(project))
     |> assign(:note_form, note_form())
     |> assign(:notes_page, 1)
     |> assign(:form, to_form(ProjectItem.changeset(%ProjectItem{}, %{}), as: "item"))
     |> load_notes(connected?(socket))}
  end

  def handle_event("add_item", %{"item" => item_params}, socket) do
    socket = refresh_authority(socket)

    if socket.assigns.can_write do
      project = socket.assigns.project
      number = String.to_integer(item_params["issue_number"])
      status = item_params["status"] || "To Do"

      case Projects.create_project_item(
             %{"issue_number" => number, "values" => %{"Status" => status}},
             project,
             socket.assigns.current_user
           ) do
        {:ok, _item} ->
          {:noreply,
           socket
           |> assign(
             :items,
             project_items(
               project,
               socket.assigns.current_user,
               socket.assigns.promise_context
             )
           )
           |> assign(:form, to_form(ProjectItem.changeset(%ProjectItem{}, %{}), as: "item"))
           |> put_flash(:info, "Issue added to project")}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Only repository members can add project items.")}
    end
  end

  def handle_event("edit_description", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_description?, socket.assigns.can_write)
     |> assign(:description_form, description_form(socket.assigns.project))}
  end

  def handle_event("cancel_description", _params, socket) do
    {:noreply, assign(socket, :editing_description?, false)}
  end

  def handle_event("save_description", %{"project" => params}, socket) do
    with true <- socket.assigns.can_write,
         {:ok, project} <-
           Projects.update_project(
             socket.assigns.project,
             Map.take(params, ["description"]),
             socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> assign(:project, project)
       |> assign(:editing_description?, false)
       |> assign(:description_form, description_form(project))
       |> reload_notes()
       |> put_flash(:info, "Description saved")}
    else
      false ->
        {:noreply, put_flash(socket, :error, "You cannot edit this project.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :description_form, to_form(changeset, as: "project"))}
    end
  end

  def handle_event("add_note", %{"note" => params}, socket) do
    with true <- socket.assigns.can_write,
         {:ok, _note} <-
           Projects.create_project_note(
             socket.assigns.project,
             params,
             socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> assign(:note_form, note_form())
       |> assign(:notes_page, 1)
       |> reload_notes()}
    else
      false ->
        {:noreply, put_flash(socket, :error, "You cannot write notes on this project.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :note_form, to_form(changeset, as: "note"))}
    end
  end

  def handle_event("delete_note", %{"id" => id}, socket) do
    note = Projects.get_project_note!(socket.assigns.project, id)

    if Projects.authored_by?(note, socket.assigns.current_user) do
      case Projects.delete_project_note(note) do
        {:ok, _note} -> {:noreply, reload_notes(socket)}
        {:error, _reason} -> {:noreply, put_flash(socket, :error, "That note cannot be deleted.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Only the author can delete a note.")}
    end
  end

  def handle_event("show_notes_page", %{"page" => page}, socket) do
    {:noreply,
     socket
     |> assign(:notes_page, max(String.to_integer(page), 1))
     |> reload_notes()}
  end

  # A project changed somewhere else — the API, the CLI, or another board — so
  # the page rereads through this viewer's authorization boundary rather than
  # trusting the broadcast payload. The message carries a repository id and
  # nothing about who may see what.
  def handle_info({:projects_changed, repository_id}, socket) do
    if repository_id == socket.assigns.repository.id do
      user = socket.assigns.current_user

      try do
        Projects.get_project_by_number!(socket.assigns.repository, socket.assigns.project.number)
      rescue
        Ecto.NoResultsError -> nil
      end
      |> case do
        nil ->
          {:noreply, put_flash(socket, :error, "This project no longer exists.")}

        project ->
          promise_context = PromiseRegistry.context(project)

          {:noreply,
           socket
           |> assign(:project, project)
           |> assign(:promise_context, promise_context)
           |> assign(:promise_registry?, promise_context.registry?)
           |> assign(:items, project_items(project, user, promise_context))
           |> reload_notes()}
      end
    else
      {:noreply, socket}
    end
  end

  defp load_notes(socket, false), do: assign(socket, :notes, :loading)
  defp load_notes(socket, true), do: reload_notes(socket)

  # The feed is a read against the database on a page that has already rendered
  # its board, so a failure here degrades the section instead of the page.
  defp reload_notes(socket) do
    page = socket.assigns.notes_page

    try do
      {notes, total_count} = Projects.list_project_notes_page(socket.assigns.project, page: page)

      socket
      |> assign(:notes, notes)
      |> assign(:notes_total_count, total_count)
      |> assign(:notes_pages, max(ceil(total_count / Projects.notes_per_page()), 1))
    rescue
      _error -> assign(socket, :notes, :error)
    end
  end

  defp description_form(project),
    do: to_form(Projects.change_project(project, %{}), as: "project")

  defp note_form, do: to_form(Projects.change_project_note(), as: "note")

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

  defp project_items(project, user, promise_context) do
    Projects.list_visible_project_items(project, user, promise_context: promise_context)
    |> Enum.map(fn item ->
      issue = item.issue
      values = PromiseRegistry.redact_values(item.values, user)

      if promise_context.registry? do
        promise = Map.get(values, "promise", %{})
        state = PromiseRegistry.state(promise_context, values)

        Map.merge(item, %{
          issue: issue,
          values: values,
          status: state,
          promise_id: promise["id"],
          verified_at: promise["verified_at"],
          evidence_count: length(promise["evidence"] || []),
          gate_missing: get_in(promise, ["gate", "missing"]),
          next_review: get_in(promise, ["gate", "next_review"])
        })
      else
        status = get_in(values, ["Status"]) || "To Do"
        Map.merge(item, %{issue: issue, values: values, status: status})
      end
    end)
  end

  defp verification_time(nil), do: "Not verified"
  defp verification_time(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")

  defp verification_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, value, _offset} -> verification_time(value)
      _ -> "Not verified"
    end
  end

  defp verification_time(_value), do: "Not verified"

  defp issue_options(repository) do
    Issues.list_issues(repository, state: "all")
    |> Enum.map(&{"##{&1.number} #{&1.title}", &1.number})
  end

  defp author(%{author: %{"login" => login}}) when is_binary(login), do: login
  defp author(_note), do: "unattributed"

  defp stamp(nil), do: nil
  defp stamp(at), do: Calendar.strftime(at, "%b %-d, %Y at %H:%M UTC")

  defp viewer(%{github_login: login}) when is_binary(login), do: login
  defp viewer(_user), do: nil

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <div class="flex items-center justify-between mb-4">
        <h1 id="project-board-title" class="text-2xl font-bold">{@project.title}</h1>
        <.link
          navigate={~p"/#{@owner}/#{@repo}/projects"}
          class="btn"
          data-variant="ghost"
          data-size="sm"
        >
          Back to projects
        </.link>
      </div>

      <section
        id="project-description"
        class="card !mx-0 !mt-0 mb-6"
        aria-labelledby="project-description-heading"
      >
        <header class="flex items-center justify-between mb-2">
          <h2 id="project-description-heading" class="card-title !text-sm">Description</h2>
          <.button
            :if={@can_write and not @editing_description?}
            id="edit-description"
            type="button"
            variant={:ghost}
            size={:sm}
            phx-click="edit_description"
          >
            Edit description
          </.button>
        </header>

        <div :if={not @editing_description?}>
          <div :if={@project.description} class="timeline-comment__body !p-0">
            {Markdown.to_html(@project.description)}
          </div>
          <.empty
            :if={is_nil(@project.description)}
            id="project-description-empty"
            title="No description yet"
          >
            A description records why this project exists and how it operates. Markdown is
            supported.
          </.empty>
        </div>

        <.form
          :if={@editing_description?}
          for={@description_form}
          id="project-description-form"
          phx-submit="save_description"
        >
          <.input
            field={@description_form[:description]}
            type="textarea"
            label="Description"
            placeholder="Why this project exists, and how it operates."
          />
          <footer class="flex justify-end gap-2 mt-2">
            <.button type="button" variant={:ghost} size={:sm} phx-click="cancel_description">
              Cancel
            </.button>
            <.button type="submit" variant={:primary} size={:sm}>Save description</.button>
          </footer>
        </.form>
      </section>

      <.form
        :if={@can_write and not @promise_registry?}
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
        <%= for status <- if(@promise_registry?, do: PromiseRegistry.states(), else: @statuses) do %>
          <section class="card !m-0 !p-3">
            <header class="mb-2">
              <h3 class="card-title !text-sm">{status}</h3>
            </header>
            <div class="space-y-2 min-h-24">
              <%= for item <- @items, item.status == status do %>
                <article class="card !m-0 !p-3">
                  <%= if @promise_registry? do %>
                    <div class="flex items-center justify-between gap-2 mb-2">
                      <span class="badge" data-variant="secondary">{item.promise_id}</span>
                      <span class="text-xs text-muted-foreground">
                        {item.evidence_count} evidence
                      </span>
                    </div>
                    <div class="text-xs text-muted-foreground mb-2">
                      Verified: {verification_time(item.verified_at)}
                    </div>
                    <%= if status == "GATED" do %>
                      <div class="text-xs text-muted-foreground mb-2">
                        Missing: {item.gate_missing} · Next review: {item.next_review}
                      </div>
                    <% end %>
                  <% end %>
                  <.link
                    navigate={
                      ~p"/#{item.issue.repository.owner}/#{item.issue.repository.name}/issues/#{item.issue.number}"
                    }
                    class="btn px-0 text-sm font-semibold"
                    data-variant="link"
                  >
                    {item.issue.title}
                  </.link>
                  <span class="text-xs text-muted-foreground block">
                    {item.issue.repository.owner}/{item.issue.repository.name}#{item.issue.number}
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

      <div id="project-discussion" class="mt-8" aria-labelledby="project-discussion-heading">
        <h2 id="project-discussion-heading" class="text-lg font-semibold mb-2">
          Discussion and activity
        </h2>

        <p :if={@notes == :loading} id="project-notes-loading" class="text-sm text-muted-foreground">
          Loading discussion…
        </p>

        <.alert
          :if={@notes == :error}
          id="project-notes-error"
          variant={:warning}
          appearance={:notice}
        >
          The discussion could not be loaded. The board above is current; reload the page to try
          again.
        </.alert>

        <%= if is_list(@notes) do %>
          <.empty :if={@notes == []} id="project-notes-empty" title="No notes yet">
            Project notes carry decisions that apply across issues. Changes to the title,
            description, or state are recorded here automatically.
          </.empty>

          <Circle.timeline :if={@notes != []}>
            <%= for note <- @notes do %>
              <Circle.timeline_event
                :if={note.kind == "activity"}
                actor={author(note)}
                text={note.body}
                icon="history"
                tone={:neutral}
                at={stamp(note.inserted_at)}
              />
              <Circle.timeline_comment
                :if={note.kind == "note"}
                id={"project-note-#{note.id}"}
                author={author(note)}
                at={stamp(note.inserted_at)}
              >
                {Markdown.to_html(note.body)}
                <:actions>
                  <.button
                    :if={Projects.authored_by?(note, @current_user)}
                    type="button"
                    variant={:ghost}
                    size={:sm}
                    phx-click="delete_note"
                    phx-value-id={note.id}
                  >
                    Delete
                  </.button>
                </:actions>
              </Circle.timeline_comment>
            <% end %>
          </Circle.timeline>

          <nav
            :if={@notes_pages > 1}
            id="project-notes-pagination"
            class="flex items-center justify-between mt-3"
            aria-label="Discussion pages"
          >
            <.button
              type="button"
              variant={:ghost}
              size={:sm}
              disabled={@notes_page <= 1}
              phx-click="show_notes_page"
              phx-value-page={@notes_page - 1}
            >
              Newer
            </.button>
            <span class="text-xs text-muted-foreground">
              Page {@notes_page} of {@notes_pages}
            </span>
            <.button
              type="button"
              variant={:ghost}
              size={:sm}
              disabled={@notes_page >= @notes_pages}
              phx-click="show_notes_page"
              phx-value-page={@notes_page + 1}
            >
              Older
            </.button>
          </nav>
        <% end %>

        <.alert
          :if={not @can_write}
          id="project-notes-unauthorized"
          variant={:info}
          appearance={:notice}
        >
          Members with write access to {@owner}/{@repo} can add notes to this project.
        </.alert>

        <.form
          :if={@can_write}
          for={@note_form}
          id="project-note-form"
          phx-submit="add_note"
          class="mt-4"
        >
          <Circle.comment_composer id="project-note-composer" author={viewer(@current_user)}>
            <.input
              field={@note_form[:body]}
              type="textarea"
              label="Note"
              placeholder="A decision, an assumption, or context that applies across issues"
            />
            <:hint>Markdown is supported.</:hint>
            <:actions>
              <.button type="submit" variant={:primary} size={:sm}>Add note</.button>
            </:actions>
          </Circle.comment_composer>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
