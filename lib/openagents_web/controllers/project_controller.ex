defmodule OpenAgentsWeb.ProjectController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Projects
  alias OpenAgents.Projects.Project
  alias OpenAgents.Repositories

  def index(conn, %{"username" => username}) do
    projects = Projects.list_projects_by_owner(username)

    render(conn, :index, projects: projects)
  end

  def create(conn, %{"owner" => owner} = params) do
    user = conn.assigns.current_user

    if String.downcase(owner) != String.downcase(user.github_login) do
      raise Ecto.NoResultsError, queryable: Project
    end

    {repository_owner, repository_name} = Repositories.initial_path()

    repository =
      Repositories.get_writable_by_path!(repository_owner, repository_name, user)

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

  def show(conn, %{"username" => username, "project_number" => project_number}) do
    project =
      Projects.get_project_by_owner_and_number!(username, String.to_integer(project_number))

    render(conn, :show, project: project)
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def items(conn, %{
        "username" => username,
        "project_number" => project_number
      }) do
    project =
      Projects.get_project_by_owner_and_number!(username, String.to_integer(project_number))

    items = Projects.list_project_items(project)
    render(conn, :items, items: items)
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def create_item(
        conn,
        %{
          "username" => username,
          "project_number" => project_number
        } = params
      ) do
    authorize_owner!(conn.assigns.current_user, username)

    project =
      Projects.get_project_by_owner_and_number!(username, String.to_integer(project_number))

    case cast_issue_number(params["issue_number"]) do
      :error ->
        unprocessable(conn, %{issue_number: ["is invalid"]})

      {:ok, issue_number} ->
        params = Map.put(params, "issue_number", issue_number)

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
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def update_item(
        conn,
        %{
          "username" => username,
          "project_number" => project_number,
          "item_id" => item_id
        } = params
      ) do
    authorize_owner!(conn.assigns.current_user, username)

    item =
      Projects.get_project_item_by_owner!(
        username,
        String.to_integer(project_number),
        String.to_integer(item_id)
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
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def fields(conn, %{
        "username" => username,
        "project_number" => project_number
      }) do
    project =
      Projects.get_project_by_owner_and_number!(username, String.to_integer(project_number))

    fields = Projects.list_project_fields(project)
    render(conn, :fields, fields: fields)
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def create_field(
        conn,
        %{
          "username" => username,
          "project_number" => project_number
        } = params
      ) do
    authorize_owner!(conn.assigns.current_user, username)

    project =
      Projects.get_project_by_owner_and_number!(username, String.to_integer(project_number))

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

  defp cast_issue_number(number) when is_integer(number), do: {:ok, number}

  defp cast_issue_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp cast_issue_number(_other), do: :error

  defp unprocessable(conn, errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end

  defp authorize_owner!(user, username) do
    if String.downcase(user.github_login) != String.downcase(username) do
      raise Ecto.NoResultsError, queryable: Project
    end

    :ok
  end

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{message: "Not Found"})
  end
end
