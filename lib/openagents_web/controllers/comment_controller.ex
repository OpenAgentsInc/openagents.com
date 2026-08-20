defmodule OpenAgentsWeb.CommentController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Comment
  alias OpenAgents.Repositories

  def index(conn, %{
        "owner" => owner,
        "repo" => repo,
        "issue_number" => issue_number
      }) do
    issue = Issues.get_issue_by_path!(owner, repo, String.to_integer(issue_number))
    comments = Issues.list_comments(issue)
    render(conn, :index, comments: comments)
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def create(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "issue_number" => issue_number
        } = params
      ) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)
    issue = Issues.get_issue_by_number!(repository, String.to_integer(issue_number))

    case Issues.create_comment(issue, params, conn.assigns.current_user) do
      {:ok, %Comment{} = comment} ->
        conn
        |> put_status(:created)
        |> render(:show, comment: comment)

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

  def show(conn, %{"owner" => owner, "repo" => repo, "id" => id}) do
    comment = Issues.get_comment_by_path!(owner, repo, String.to_integer(id))
    render(conn, :show, comment: comment)
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def update(conn, %{"owner" => owner, "repo" => repo, "id" => id} = params) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)
    comment = Issues.get_comment!(repository, String.to_integer(id))

    case Issues.update_comment(comment, params) do
      {:ok, %Comment{} = comment} ->
        render(conn, :show, comment: comment)

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

  def delete(conn, %{"owner" => owner, "repo" => repo, "id" => id}) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)
    comment = Issues.get_comment!(repository, String.to_integer(id))

    case Issues.delete_comment(comment) do
      {:ok, :ok} ->
        send_resp(conn, :no_content, "")

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{message: "Could not delete comment"})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end
end
