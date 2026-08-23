defmodule OpenAgentsWeb.CommentController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Comment
  alias OpenAgents.Agents.Agent
  alias OpenAgents.Repositories

  def index(conn, %{
        "owner" => owner,
        "repo" => repo,
        "issue_number" => issue_number
      }) do
    issue =
      Issues.get_issue_by_path!(
        owner,
        repo,
        OpenAgentsWeb.ControllerHelpers.integer_param!(issue_number)
      )

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
    actor = conn.assigns[:current_agent] || conn.assigns[:current_user]

    repository =
      case actor do
        %Agent{} -> Repositories.get_public_by_path!(owner, repo)
        _ -> Repositories.get_writable_by_path!(owner, repo, actor)
      end

    issue =
      Issues.get_issue_by_number!(
        repository,
        OpenAgentsWeb.ControllerHelpers.integer_param!(issue_number)
      )

    if Repositories.issue_participant?(repository, actor) do
      case Issues.create_comment(issue, params, actor) do
        {:ok, %Comment{} = comment} ->
          conn
          |> put_status(:created)
          |> render(:show, comment: comment)

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, changeset: changeset)
      end
    else
      participation_forbidden(conn, actor)
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  defp participation_forbidden(conn, %Agent{}),
    do:
      conn
      |> put_status(:forbidden)
      |> json(%{"error" => %{"code" => "agent_participation_forbidden"}})

  defp participation_forbidden(conn, _actor),
    do: conn |> put_status(:forbidden) |> json(%{"error" => "forbidden"})

  def show(conn, %{"owner" => owner, "repo" => repo, "id" => id}) do
    comment =
      Issues.get_comment_by_path!(owner, repo, OpenAgentsWeb.ControllerHelpers.integer_param!(id))

    render(conn, :show, comment: comment)
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def update(conn, %{"owner" => owner, "repo" => repo, "id" => id} = params) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)
    comment = Issues.get_comment!(repository, OpenAgentsWeb.ControllerHelpers.integer_param!(id))

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
    comment = Issues.get_comment!(repository, OpenAgentsWeb.ControllerHelpers.integer_param!(id))

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
