defmodule OpenAgentsWeb.CommentController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Comment

  def index(conn, %{
        "owner" => _owner,
        "repo" => _repo,
        "issue_number" => issue_number
      }) do
    issue = Issues.get_issue_by_number!(String.to_integer(issue_number))
    comments = Issues.list_comments(issue.id)
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
          "owner" => _owner,
          "repo" => _repo,
          "issue_number" => issue_number
        } = params
      ) do
    issue = Issues.get_issue_by_number!(String.to_integer(issue_number))

    case Issues.create_comment(Map.put(params, :issue_id, issue.id)) do
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

  def show(conn, %{"owner" => _owner, "repo" => _repo, "id" => id}) do
    comment = Issues.get_comment!(String.to_integer(id))
    render(conn, :show, comment: comment)
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def update(conn, %{"owner" => _owner, "repo" => _repo, "id" => id} = params) do
    comment = Issues.get_comment!(String.to_integer(id))

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

  def delete(conn, %{"owner" => _owner, "repo" => _repo, "id" => id}) do
    comment = Issues.get_comment!(String.to_integer(id))

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
