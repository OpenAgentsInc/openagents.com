defmodule OpenAgentsWeb.ProjectController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Projects
  alias OpenAgents.Projects.Project
  alias OpenAgents.Repositories

  def index(conn, %{"owner" => owner, "repo" => repo}) do
    repository = visible_repository!(conn, owner, repo)
    render(conn, :index, projects: Projects.list_projects(repository))
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
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
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
  Updates the title, description, or state of one project.

  Authority is a writable membership in the repository the path names, the same
  boundary every other project write reads. `description` is Markdown, and
  `state` is `open` or `closed`.
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
    attrs = Map.take(params, ["title", "description", "state"])

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
            conn
            |> put_status(:unprocessable_entity)
            |> render(:error, changeset: changeset)
        end
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
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
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

  defp valid_state?(%{"state" => state}), do: state in ["open", "closed"]
  defp valid_state?(_attrs), do: true

  def items(conn, %{
        "owner" => owner,
        "repo" => repo,
        "project_number" => project_number
      }) do
    repository = visible_repository!(conn, owner, repo)
    project = Projects.get_project_by_number!(repository, parse_id!(project_number))

    render(conn, :items,
      items: Projects.list_visible_project_items(project, conn.assigns[:current_user])
    )
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

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

        case Projects.create_project_item(params, project, conn.assigns.current_user) do
          {:ok, item} ->
            conn
            |> put_status(:created)
            |> render(:items, items: [item])

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> render(:error, changeset: changeset)
        end
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
      case Projects.update_project_item(item, params) do
        {:ok, item} ->
          render(conn, :items, items: [item])

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, changeset: changeset)
      end
    else
      unprocessable(conn, %{values: ["is invalid"]})
    end
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

    case Projects.create_project_field(attrs) do
      {:ok, field} ->
        conn
        |> put_status(:created)
        |> render(:fields, fields: [field])

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
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

  defp unprocessable(conn, errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end

  defp unprocessable_changeset(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> render(:error, changeset: changeset)
  end

  defp forbidden(conn) do
    conn |> put_status(:forbidden) |> json(%{message: "Forbidden"})
  end

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{message: "Not Found"})
  end
end
