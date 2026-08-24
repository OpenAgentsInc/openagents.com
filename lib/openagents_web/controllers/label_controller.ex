defmodule OpenAgentsWeb.LabelController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Labels
  alias OpenAgents.Labels.Label
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.ApiError

  def index(conn, %{"owner" => owner, "repo" => repo}) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])
    labels = Labels.list_labels(repository)
    render(conn, :index, labels: labels, owner: owner, repo: repo)
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def create(conn, %{"owner" => owner, "repo" => repo} = params) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)

    case Labels.create_label(repository, params, conn.assigns.current_user) do
      {:ok, %Label{} = label} ->
        conn
        |> put_status(:created)
        |> render(:show, label: label, owner: owner, repo: repo)

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def show(conn, %{"owner" => owner, "repo" => repo, "name" => name}) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])
    label = Labels.get_label_by_name!(repository, name)
    render(conn, :show, label: label, owner: owner, repo: repo)
  rescue
    Ecto.NoResultsError -> ApiError.not_found(conn)
  end

  def update(conn, %{"owner" => owner, "repo" => repo, "name" => name} = params) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)
    label = Labels.get_label_by_name!(repository, name)

    # GitHub renames through `new_name`; without this the path's name always
    # won and the rename was silently dropped.
    attrs =
      case params["new_name"] do
        nil -> params
        new_name -> Map.put(params, "name", new_name)
      end

    case Labels.update_label(label, attrs) do
      {:ok, %Label{} = label} ->
        render(conn, :show, label: label, owner: owner, repo: repo)

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> ApiError.not_found(conn)
  end

  def delete(conn, %{"owner" => owner, "repo" => repo, "name" => name}) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)
    label = Labels.get_label_by_name!(repository, name)

    case Labels.delete_label(label) do
      {:ok, %Label{}} ->
        send_resp(conn, :no_content, "")

      {:error, _reason} ->
        ApiError.refuse(conn, "delete_failed", message: "Could not delete label")
    end
  rescue
    Ecto.NoResultsError -> ApiError.not_found(conn)
  end

  defp not_found(conn), do: ApiError.not_found(conn)
end
