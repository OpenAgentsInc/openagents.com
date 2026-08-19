defmodule OpenAgentsWeb.LabelController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Labels
  alias OpenAgents.Labels.Label

  def index(conn, %{"owner" => owner, "repo" => repo}) do
    labels = Labels.list_labels()
    render(conn, :index, labels: labels, owner: owner, repo: repo)
  end

  def create(conn, %{"owner" => owner, "repo" => repo} = params) do
    case Labels.create_label(params) do
      {:ok, %Label{} = label} ->
        conn
        |> put_status(:created)
        |> render(:show, label: label, owner: owner, repo: repo)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  def show(conn, %{"owner" => owner, "repo" => repo, "name" => name}) do
    label = Labels.get_label_by_name!(name)
    render(conn, :show, label: label, owner: owner, repo: repo)
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def update(conn, %{"owner" => owner, "repo" => repo, "name" => name} = params) do
    label = Labels.get_label_by_name!(name)

    case Labels.update_label(label, params) do
      {:ok, %Label{} = label} ->
        render(conn, :show, label: label, owner: owner, repo: repo)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def delete(conn, %{"owner" => _owner, "repo" => _repo, "name" => name}) do
    label = Labels.get_label_by_name!(name)

    case Labels.delete_label(label) do
      {:ok, %Label{}} ->
        send_resp(conn, :no_content, "")

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{message: "Could not delete label"})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end
end
