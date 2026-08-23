defmodule OpenAgentsWeb.ProjectController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Issues.Issue
  alias OpenAgents.Projects
  alias OpenAgents.Projects.Project
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.ApiError

  @doc """
  The repository's projects.

  Archived projects are out of the working set, so the list leaves them out
  until `archived=true` asks for them.
  """
  def index(conn, %{"owner" => owner, "repo" => repo} = params) do
    repository = visible_repository!(conn, owner, repo)
    projects = Projects.list_projects(repository, archived: params["archived"] == "true")
    render(conn, :index, projects: projects)
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def create(conn, %{"owner" => owner, "repo" => repo} = params) do
    user = conn.assigns.current_user
    repository = Repositories.get_writable_by_path!(owner, repo, user)

    case Projects.create_project(repository, params, user) do
      {:ok, %Project{} = project} ->
        conn
        |> put_status(:created)
        |> render(:show, project: project)

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def show(conn, %{
        "owner" => owner,
        "repo" => repo,
        "project_number" => project_number
      }) do
    repository = visible_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))
    render(conn, :show, project: project)
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  @doc """
  Updates the title, description, state, or archive standing of one project.

  Authority is a writable membership in the repository the path names, the same
  boundary every other project write reads. `description` is Markdown, `state`
  is `open` or `closed`, and `archived` is a boolean.

  Closing and reopening move `state`. Archiving is a separate axis: a closed
  project says the work reached an end, an archived project says the board left
  the working set, whatever became of the work.
  """
  def update(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "project_number" => project_number
        } = params
      ) do
    repository = writable_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))
    attrs = params |> Map.take(["title", "description", "state", "archived"]) |> cast_archived()

    cond do
      attrs == %{} ->
        unprocessable(conn, %{base: ["no updatable field was given"]})

      not valid_state?(attrs) ->
        unprocessable(conn, %{state: ["is invalid"]})

      true ->
        case Projects.update_project(project, attrs, conn.assigns.current_user) do
          {:ok, %Project{} = project} ->
            render(conn, :show, project: project)

          {:error, %Ecto.Changeset{} = changeset} ->
            ApiError.changeset(conn, changeset)
        end
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  @doc """
  Deletes one project, its fields, its items, and its item events.

  The policy is two keys, not one: a writable membership in the repository, and
  a project already in the archive. The board surface pairs its delete control
  with a confirmation prompt; an API caller has no prompt, so archiving is the
  deliberate step that stands in for one. The referenced issues are untouched —
  an item points at canonical work rather than owning it.
  """
  def delete(conn, %{
        "owner" => owner,
        "repo" => repo,
        "project_number" => project_number
      }) do
    repository = writable_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))

    if Project.archived?(project) do
      case Projects.delete_project(project) do
        {:ok, %Project{}} ->
          send_resp(conn, :no_content, "")

        {:error, %Ecto.Changeset{} = changeset} ->
          unprocessable_changeset(conn, changeset)
      end
    else
      unprocessable(conn, %{archived: ["the project must be archived before it deletes"]})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  @doc """
  One page of a project's notes, newest first.

  Reads follow the repository's visibility, so a private project's notes stay
  invisible to a non-member: the request 404s at the repository before a note
  is read. Query parameters are `page` and `kind`, where `kind` is `note`,
  `activity`, or `all`.
  """
  def notes(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "project_number" => project_number
        } = params
      ) do
    repository = visible_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))
    page = Projects.parse_page(params["page"])

    {notes, total_count} =
      Projects.list_project_notes_page(project, page: page, kind: params["kind"])

    render(conn, :notes, notes: notes, page: page, total_count: total_count)
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  @doc "Writes one discussion note on a project."
  def create_note(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "project_number" => project_number
        } = params
      ) do
    repository = writable_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))

    case Projects.create_project_note(project, params, conn.assigns.current_user) do
      {:ok, note} ->
        conn
        |> put_status(:created)
        |> render(:note, note: note)

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  @doc """
  Edits one discussion note.

  Authority is the note's author. Repository write access is necessary but not
  sufficient: another member adds a note of their own rather than rewriting
  this one, and an activity entry is never editable.
  """
  def update_note(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "project_number" => project_number,
          "note_id" => note_id
        } = params
      ) do
    with {:ok, note} <- authored_note(conn, owner, repo, project_number, note_id),
         {:ok, note} <- Projects.update_project_note(note, params) do
      render(conn, :note, note: note)
    else
      {:error, :forbidden} -> forbidden(conn)
      {:error, :immutable} -> forbidden(conn)
      {:error, %Ecto.Changeset{} = changeset} -> unprocessable_changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  @doc "Deletes one discussion note. Authority is the note's author."
  def delete_note(conn, %{
        "owner" => owner,
        "repo" => repo,
        "project_number" => project_number,
        "note_id" => note_id
      }) do
    with {:ok, note} <- authored_note(conn, owner, repo, project_number, note_id),
         {:ok, _note} <- Projects.delete_project_note(note) do
      send_resp(conn, :no_content, "")
    else
      {:error, :forbidden} -> forbidden(conn)
      {:error, :immutable} -> forbidden(conn)
      {:error, %Ecto.Changeset{} = changeset} -> unprocessable_changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  defp authored_note(conn, owner, repo, project_number, note_id) do
    repository = writable_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))
    note = Projects.get_project_note!(project, parse_id!(note_id))

    if Projects.authored_by?(note, conn.assigns.current_user) do
      {:ok, note}
    else
      {:error, :forbidden}
    end
  end

  defp valid_state?(%{"state" => state}), do: state in Project.states()
  defp valid_state?(_attrs), do: true

  # A JSON client sends a boolean; a form-encoded client sends the word. Both
  # mean the same thing, and anything else stays invalid so the context can say
  # so.
  defp cast_archived(%{"archived" => "true"} = attrs), do: %{attrs | "archived" => true}
  defp cast_archived(%{"archived" => "false"} = attrs), do: %{attrs | "archived" => false}
  defp cast_archived(attrs), do: attrs

  def items(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "project_number" => project_number
        } = params
      ) do
    repository = visible_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))

    with {:ok, opts} <- item_filters(params) do
      {items, item_projections} =
        Projects.list_visible_project_items_with_promises(
          project,
          conn.assigns[:current_user],
          opts
        )

      render(conn, :items,
        items: items,
        viewer: conn.assigns[:current_user],
        item_projections: item_projections
      )
    else
      {:error, field, message} -> unprocessable(conn, %{field => [message]})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  @doc """
  Adds one issue to a project.

  Membership is a set: an issue is on a board once. A repeated add is answered
  with `200` and the membership the board already has, rather than `422`,
  because a client that retries a request it never saw the answer to has asked
  for a state that already holds. The same issue can sit on several boards,
  because an item is a board's view of canonical work rather than the work.
  """
  def create_item(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "project_number" => project_number
        } = params
      ) do
    repository = writable_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))

    case issue_reference(conn, repository, params) do
      :error ->
        unprocessable(conn, %{issue_number: ["is invalid"]})

      {:ok, source_repository, issue_number} ->
        params =
          params
          |> Map.put("issue_number", issue_number)
          |> Map.put("issue_repository_id", source_repository.id)

        existing =
          case Repo.get_by(Issue, repository_id: source_repository.id, number: issue_number) do
            nil -> nil
            issue -> Projects.project_item_for_issue(project, issue.id)
          end

        case Projects.create_project_item(params, project, conn.assigns.current_user) do
          {:ok, item} ->
            conn
            |> put_status(if(existing, do: :ok, else: :created))
            |> render_items([item], project)

          {:error, %Ecto.Changeset{} = changeset} ->
            ApiError.changeset(conn, changeset)
        end
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  @doc """
  Removes one item from a project.

  The item goes, the issue stays. A second `DELETE` on the same item returns
  `404`, because the item is gone and the path names nothing: the board's state
  after both requests is the same one.
  """
  def delete_item(conn, %{
        "owner" => owner,
        "repo" => repo,
        "project_number" => project_number,
        "item_id" => item_id
      }) do
    repository = writable_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))

    item =
      Projects.get_visible_project_item!(
        project,
        parse_id!(item_id),
        conn.assigns.current_user
      )

    case Projects.delete_project_item(item, conn.assigns.current_user) do
      {:ok, _item} -> send_resp(conn, :no_content, "")
      {:error, %Ecto.Changeset{} = changeset} -> unprocessable_changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  @doc """
  Moves one item to another column, another rank, or both.

  The body carries `values`, merged the way `PATCH` merges them, and
  `position`, a one-based rank within the destination column. A body with only
  `position` is a reorder. A body with only `values` lands the card at the end
  of the column it names. A stale option identifier the field no longer offers
  is refused with `422` and changes nothing.
  """
  def move_item(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "project_number" => project_number,
          "item_id" => item_id
        } = params
      ) do
    repository = writable_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))

    item =
      Projects.get_visible_project_item!(
        project,
        parse_id!(item_id),
        conn.assigns.current_user
      )

    attrs = Map.take(params, ["values", "position"])

    if is_map(Map.get(attrs, "values", %{})) do
      case Projects.move_project_item(item, attrs, conn.assigns.current_user) do
        {:ok, item} ->
          render_items(conn, [item], project)

        {:error, %Ecto.Changeset{} = changeset} ->
          unprocessable_changeset(conn, changeset)
      end
    else
      unprocessable(conn, %{values: ["is invalid"]})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def update_item(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "project_number" => project_number,
          "item_id" => item_id
        } = params
      ) do
    repository = writable_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))

    item =
      Projects.get_visible_project_item!(
        project,
        parse_id!(item_id),
        conn.assigns.current_user
      )

    if is_map(Map.get(params, "values", %{})) do
      case Projects.update_project_item(item, params, conn.assigns.current_user) do
        {:ok, item} ->
          render_items(conn, [item], project)

        {:error, %Ecto.Changeset{} = changeset} ->
          ApiError.changeset(conn, changeset)
      end
    else
      unprocessable(conn, %{values: ["is invalid"]})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def events(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "project_number" => project_number,
          "item_id" => item_id
        } = params
      ) do
    repository = visible_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))

    item =
      Projects.get_visible_project_item!(
        project,
        parse_id!(item_id),
        conn.assigns[:current_user]
      )

    {events, total, page, per_page} =
      Projects.list_project_item_events(item, page: params["page"])

    render(conn, :events,
      events: Projects.project_item_events(events, conn.assigns[:current_user]),
      pagination: %{page: page, per_page: per_page, total: total},
      viewer: conn.assigns[:current_user]
    )
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def fields(conn, %{
        "owner" => owner,
        "repo" => repo,
        "project_number" => project_number
      }) do
    repository = visible_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))
    render(conn, :fields, fields: Projects.list_project_fields(project))
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def create_field(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "project_number" => project_number
        } = params
      ) do
    repository = writable_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))

    attrs =
      params
      |> Map.take(["name", "data_type", "options"])
      |> Map.put("project_id", project.id)

    case Projects.create_project_field(attrs, conn.assigns.current_user) do
      {:ok, field} ->
        conn
        |> put_status(:created)
        |> render(:fields, fields: [field])

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  @doc """
  Updates one field of a project.

  A rename carries the values with it: the field name is the key an item stores
  its value under, so the rename rewrites that key on every item of the project
  in the same transaction. The data type never changes, and an option items
  still carry cannot be dropped.
  """
  def update_field(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "project_number" => project_number,
          "field_id" => field_id
        } = params
      ) do
    repository = writable_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))
    field = Projects.get_project_field!(project, parse_id!(field_id))
    attrs = Map.take(params, ["name", "data_type", "options"])

    if attrs == %{} do
      unprocessable(conn, %{base: ["no updatable field was given"]})
    else
      case Projects.update_project_field(project, field, attrs, conn.assigns.current_user) do
        {:ok, field} ->
          render(conn, :fields, fields: [field])

        {:error, %Ecto.Changeset{} = changeset} ->
          unprocessable_changeset(conn, changeset)
      end
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  @doc """
  Removes one field of a project.

  A field whose values items still carry is preserved and the request returns
  `422`: deleting it would leave those values keyed to a column nothing
  declares, which is data loss reported as success.
  """
  def delete_field(conn, %{
        "owner" => owner,
        "repo" => repo,
        "project_number" => project_number,
        "field_id" => field_id
      }) do
    repository = writable_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))
    field = Projects.get_project_field!(project, parse_id!(field_id))

    case Projects.delete_project_field(project, field, conn.assigns.current_user) do
      {:ok, _field} ->
        send_resp(conn, :no_content, "")

      {:error, %Ecto.Changeset{} = changeset} ->
        unprocessable_changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  defp visible_repository!(conn, owner, repo) do
    Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])
  end

  defp writable_repository!(conn, owner, repo) do
    Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)
  end

  defp parse_id!(value) do
    case cast_number(value) do
      {:ok, number} -> number
      :error -> raise Ecto.NoResultsError, queryable: Project
    end
  end

  defp cast_number(number) when is_integer(number), do: {:ok, number}

  defp cast_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp cast_number(_other), do: :error

  defp issue_reference(conn, _project_repository, %{"issue" => issue}) when is_map(issue) do
    with owner when is_binary(owner) <- issue["owner"],
         repo when is_binary(repo) <- issue["repo"],
         {:ok, number} <- cast_number(issue["number"]) do
      {:ok, visible_repository!(conn, owner, repo), number}
    else
      _invalid -> :error
    end
  end

  defp issue_reference(_conn, project_repository, params) do
    case cast_number(params["issue_number"]) do
      {:ok, number} -> {:ok, project_repository, number}
      :error -> :error
    end
  end

  defp unprocessable(conn, errors), do: ApiError.validation_failed(conn, errors)

  defp unprocessable_changeset(conn, changeset), do: ApiError.changeset(conn, changeset)

  defp forbidden(conn), do: ApiError.forbidden(conn)

  defp item_filters(params) do
    state = params["promise_state"]
    bounty = params["bounty_candidate"]

    cond do
      state && state not in ~w(LIVE GATED WITHDRAWN) ->
        {:error, :promise_state, "must be one of: LIVE, GATED, WITHDRAWN"}

      bounty && bounty not in ~w(true false) ->
        {:error, :bounty_candidate, "must be true or false"}

      true ->
        {:ok,
         [
           promise_state: state,
           bounty_candidate: if(bounty, do: bounty == "true")
         ]
         |> Enum.reject(fn {_key, value} -> is_nil(value) end)}
    end
  end

  defp render_items(conn, items, project) do
    render(conn, :items,
      items: items,
      viewer: conn.assigns[:current_user],
      item_projections:
        Projects.project_item_projections(
          items,
          OpenAgents.Projects.PromiseRegistry.context(project),
          conn.assigns[:current_user]
        )
    )
  end

  defp not_found(conn), do: ApiError.not_found(conn)
end
