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

  # A board renders the columns its project stores, so a heading is a field
  # option's label and a column key is that option's identifier -- both stored
  # data. A stream name, meanwhile, has to be a fixed atom. The two are related
  # by *position*: column zero of any board is carried by the first stream in
  # this compile-time pool, column one by the second, and so on. Nothing here
  # is derived from a stored value, so `String.to_atom/1` is never called on
  # one. The pool covers the largest option list a field can declare, plus one
  # column for the cards whose stored value the field no longer offers.
  @max_board_columns 101
  @column_streams for index <- 0..(@max_board_columns - 1), do: :"board_column_#{index}"

  @unsorted_column_name "No status"

  def mount(%{"owner" => owner, "repo" => repo, "number" => number}, _session, socket) do
    user = socket.assigns.current_user
    repository = visible_repository!(owner, repo, user)
    project = Projects.get_project_by_number!(repository, String.to_integer(number))
    can_write = Repositories.writable?(repository, user)

    if connected?(socket), do: Repositories.subscribe_projects(repository.id)
    promise_context = PromiseRegistry.context(project)
    issue_options = issue_options(repository)

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> assign(:project, project)
     |> assign(:can_write, can_write)
     |> assign(:issue_options, issue_options)
     |> assign(:editing_description?, false)
     |> assign(:description_form, description_form(project))
     |> assign(:note_form, note_form())
     |> assign(:notes_page, 1)
     |> assign(:form, to_form(ProjectItem.changeset(%ProjectItem{}, %{}), as: "item"))
     |> load_board(project, promise_context)
     |> load_notes(connected?(socket))}
  end

  def handle_event("add_item", %{"item" => item_params}, socket) do
    socket = refresh_authority(socket)

    if socket.assigns.can_write do
      project = socket.assigns.project
      grouping = socket.assigns.grouping
      number = String.to_integer(item_params["issue_number"])
      status = item_params["status"] || default_column_id(socket.assigns.columns)

      case Projects.create_project_item(
             %{"issue_number" => number, "values" => %{grouping.field_name => status}},
             project,
             socket.assigns.current_user
           ) do
        {:ok, _item} ->
          {:noreply,
           socket
           |> load_board(project, socket.assigns.promise_context)
           |> assign(:form, to_form(ProjectItem.changeset(%ProjectItem{}, %{}), as: "item"))
           |> put_flash(:info, "Issue added to project")}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Only repository members can add project items.")}
    end
  end

  # A move is one write, not a drag: **Move left**, **Move right**, **Move up**,
  # and **Move down** are ordinary buttons, so the keyboard and a screen reader
  # reach them the same way a pointer does, and no client-side ordering state
  # can disagree with what committed.
  def handle_event("move_item", %{"id" => id, "direction" => direction}, socket) do
    socket = refresh_authority(socket)

    if socket.assigns.can_write do
      project = socket.assigns.project
      user = socket.assigns.current_user
      item = Projects.get_visible_project_item!(project, id, user)

      case move_attrs(direction, item, socket) do
        :none ->
          {:noreply, socket}

        attrs ->
          case Projects.move_project_item(item, attrs, user) do
            {:ok, _item} ->
              {:noreply, load_board(socket, project, socket.assigns.promise_context)}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, "That card could not be moved.")}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "Only repository members can move project items.")}
    end
  end

  def handle_event("remove_item", %{"id" => id}, socket) do
    socket = refresh_authority(socket)

    if socket.assigns.can_write do
      project = socket.assigns.project
      item = Projects.get_visible_project_item!(project, id, socket.assigns.current_user)

      case Projects.delete_project_item(item, socket.assigns.current_user) do
        {:ok, _item} ->
          {:noreply,
           socket
           |> load_board(project, socket.assigns.promise_context)
           |> put_flash(:info, "Item removed from project")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "That item could not be removed.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Only repository members can remove project items.")}
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
  # nothing about who may see what, so a card in a repository this viewer
  # cannot read is filtered out on the re-read exactly as it was on mount.
  def handle_info({:projects_changed, repository_id}, socket) do
    if repository_id == socket.assigns.repository.id do
      try do
        Projects.get_project_by_number!(socket.assigns.repository, socket.assigns.project.number)
      rescue
        Ecto.NoResultsError -> nil
      end
      |> case do
        nil ->
          {:noreply, put_flash(socket, :error, "This project no longer exists.")}

        project ->
          {:noreply,
           socket
           |> assign(:project, project)
           |> load_board(project, PromiseRegistry.context(project))
           |> reload_notes()}
      end
    else
      {:noreply, socket}
    end
  end

  # The board is rebuilt from the database on every change rather than patched
  # from a payload: a status change moves a card between columns, and a card
  # that stayed put after its status moved is worse than a redraw. Each column
  # is its own stream and each redraw resets it, so the client applies the move
  # as a removal and an insertion instead of replacing the page.
  defp load_board(socket, project, promise_context) do
    grouping = Projects.board_grouping(project)
    items = project_items(project, socket.assigns.current_user, promise_context, grouping)
    grouped = Enum.group_by(items, & &1.column_id)
    columns = board_columns(grouping, grouped)

    socket
    |> assign(:promise_context, promise_context)
    |> assign(:promise_registry?, promise_context.registry?)
    |> assign(:grouping, grouping)
    |> assign(:columns, columns)
    |> assign(:status_options, Enum.map(grouping.columns, &{&1.name, &1.id}))
    |> then(
      &Enum.reduce(columns, &1, fn column, socket ->
        stream(socket, column.stream, Map.get(grouped, column.id, []), reset: true)
      end)
    )
  end

  # The declared options are the board, in the order the field declares them. A
  # card whose stored value the field no longer offers is stale rather than
  # missing, so it gets a column of its own instead of disappearing -- and that
  # column exists only while something is in it.
  defp board_columns(grouping, grouped) do
    declared = Enum.take(grouping.columns, @max_board_columns - 1)

    unsorted =
      case Map.get(grouped, nil, []) do
        [] -> []
        _stale -> [%{id: nil, name: @unsorted_column_name}]
      end

    (declared ++ unsorted)
    |> Enum.with_index()
    |> Enum.map(fn {column, index} ->
      Map.merge(column, %{
        stream: Enum.at(@column_streams, index),
        dom_id: "project-column-#{index}"
      })
    end)
  end

  defp default_column_id([%{id: id} | _rest]), do: id
  defp default_column_id(_columns), do: nil

  defp move_attrs("up", item, socket), do: rank_attrs(item, socket, -1)
  defp move_attrs("down", item, socket), do: rank_attrs(item, socket, 1)
  defp move_attrs("left", item, socket), do: column_attrs(item, socket, -1)
  defp move_attrs("right", item, socket), do: column_attrs(item, socket, 1)
  defp move_attrs(_direction, _item, _socket), do: :none

  defp rank_attrs(item, socket, offset) do
    members = column_members(item, socket)
    rank = Enum.find_index(members, &(&1.id == item.id))

    case rank do
      nil -> :none
      rank -> %{"position" => min(max(rank + 1 + offset, 1), length(members))}
    end
  end

  defp column_attrs(item, socket, offset) do
    %{grouping: grouping, columns: columns} = socket.assigns
    current = Projects.board_column_id(grouping, item.values)
    index = Enum.find_index(columns, &(&1.id == current))

    with index when is_integer(index) <- index,
         target when target >= 0 <- index + offset,
         %{id: id} when not is_nil(id) <- Enum.at(columns, index + offset) do
      %{"values" => %{grouping.field_name => id}}
    else
      _out_of_range -> :none
    end
  end

  defp column_members(item, socket) do
    %{grouping: grouping, project: project} = socket.assigns
    column = Projects.board_column_id(grouping, item.values)

    project
    |> Projects.list_visible_project_items(socket.assigns.current_user)
    |> Enum.filter(&(Projects.board_column_id(grouping, &1.values) == column))
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

  defp project_items(project, user, promise_context, grouping) do
    Projects.list_visible_project_items(project, user, promise_context: promise_context)
    |> Enum.map(fn item ->
      issue = item.issue
      values = PromiseRegistry.redact_values(item.values, user)
      column_id = Projects.board_column_id(grouping, values)

      if promise_context.registry? do
        promise = Map.get(values, "promise", %{})

        Map.merge(item, %{
          issue: issue,
          values: values,
          column_id: column_id,
          promise_id: promise["id"],
          verified_at: promise["verified_at"],
          evidence_count: length(promise["evidence"] || []),
          gate_missing: get_in(promise, ["gate", "missing"]),
          next_review: get_in(promise, ["gate", "next_review"])
        })
      else
        Map.merge(item, %{issue: issue, values: values, column_id: column_id})
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

      <div
        id="project-board"
        class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-4 items-start"
        role="list"
        aria-label={"#{@grouping.field_name} columns"}
      >
        <%= for {column, column_index} <- Enum.with_index(@columns) do %>
          <section class="card !m-0 !p-3" role="listitem" aria-labelledby={"#{column.dom_id}-heading"}>
            <header class="mb-2">
              <h3 id={"#{column.dom_id}-heading"} class="card-title !text-sm">{column.name}</h3>
            </header>
            <div
              id={column.dom_id}
              data-column={column.id}
              data-unsorted={is_nil(column.id) && "true"}
              class="space-y-2 min-h-24"
              phx-update="stream"
            >
              <p
                id={"#{column.dom_id}-empty"}
                class="hidden only:block text-xs text-muted-foreground"
              >
                No cards in this column.
              </p>
              <%= for {dom_id, item} <- @streams[column.stream] do %>
                <article id={dom_id} class="card !m-0 !p-3">
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
                    <%= if column.id == "GATED" do %>
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
                  <div
                    :if={@can_write}
                    class="flex flex-wrap items-center gap-1 mt-3 border-t border-border pt-2"
                    role="group"
                    aria-label={"Move or remove #{item.issue.title}"}
                  >
                    <.button
                      id={"move-left-#{item.id}"}
                      type="button"
                      variant={:ghost}
                      size={:sm}
                      disabled={column_index == 0}
                      phx-click="move_item"
                      phx-value-id={item.id}
                      phx-value-direction="left"
                      aria-label={"Move #{item.issue.title} to the previous column"}
                    >
                      Move left
                    </.button>
                    <.button
                      id={"move-right-#{item.id}"}
                      type="button"
                      variant={:ghost}
                      size={:sm}
                      disabled={column_index >= length(@columns) - 1 or is_nil(column.id)}
                      phx-click="move_item"
                      phx-value-id={item.id}
                      phx-value-direction="right"
                      aria-label={"Move #{item.issue.title} to the next column"}
                    >
                      Move right
                    </.button>
                    <.button
                      id={"move-up-#{item.id}"}
                      type="button"
                      variant={:ghost}
                      size={:sm}
                      phx-click="move_item"
                      phx-value-id={item.id}
                      phx-value-direction="up"
                      aria-label={"Move #{item.issue.title} up in this column"}
                    >
                      Move up
                    </.button>
                    <.button
                      id={"move-down-#{item.id}"}
                      type="button"
                      variant={:ghost}
                      size={:sm}
                      phx-click="move_item"
                      phx-value-id={item.id}
                      phx-value-direction="down"
                      aria-label={"Move #{item.issue.title} down in this column"}
                    >
                      Move down
                    </.button>
                    <.button
                      id={"remove-item-#{item.id}"}
                      type="button"
                      variant={:ghost}
                      size={:sm}
                      tone={:danger}
                      phx-click="remove_item"
                      phx-value-id={item.id}
                      data-confirm={"Remove #{item.issue.title} from this project?"}
                      aria-label={"Remove #{item.issue.title} from this project"}
                    >
                      Remove
                    </.button>
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
