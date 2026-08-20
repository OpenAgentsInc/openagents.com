defmodule OpenAgentsWeb.ProjectController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Projects
  alias OpenAgents.Projects.Project

  def index(conn, %{"username" => username}) do
    projects =
      Projects.list_projects()
      |> Enum.filter(&(&1.owner == username))

    render(conn, :index, projects: projects)
  end

  def create(conn, %{"owner" => owner} = params) do
    attrs =
      params
      |> Map.put("owner", owner)

    case Projects.create_project(attrs) do
      {:ok, %Project{} = project} ->
        conn
        |> put_status(:created)
        |> render(:show, project: project)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  def show(conn, %{"username" => _username, "project_number" => project_number}) do
    project = Projects.get_project_by_number!(String.to_integer(project_number))
    render(conn, :show, project: project)
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def items(conn, %{
        "username" => _username,
        "project_number" => project_number
      }) do
    project = Projects.get_project_by_number!(String.to_integer(project_number))
    items = Projects.list_project_items(project.id)
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
          "username" => _username,
          "project_number" => project_number
        } = params
      ) do
    project = Projects.get_project_by_number!(String.to_integer(project_number))

    case cast_issue_number(params["issue_number"]) do
      :error ->
        unprocessable(conn, %{issue_number: ["is invalid"]})

      {:ok, issue_number} ->
        params = Map.put(params, "issue_number", issue_number)

        case Projects.create_project_item(params, project.id) do
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
          "username" => _username,
          "project_number" => _project_number,
          "item_id" => item_id
        } = params
      ) do
    item = Projects.get_project_item!(String.to_integer(item_id))

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
        "username" => _username,
        "project_number" => project_number
      }) do
    project = Projects.get_project_by_number!(String.to_integer(project_number))
    fields = Projects.list_project_fields(project.id)
    render(conn, :fields, fields: fields)
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
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
end
