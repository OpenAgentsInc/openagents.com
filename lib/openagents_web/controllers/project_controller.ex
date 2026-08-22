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

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{message: "Not Found"})
  end
end
