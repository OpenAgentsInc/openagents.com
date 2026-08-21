defmodule OpenAgentsWeb.IssueController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Repositories

  def index(conn, %{"owner" => owner, "repo" => repo} = params) do
    state = Map.get(params, "state", "open")
    repository = Repositories.get_public_by_path!(owner, repo)
    issues = Issues.list_issues(repository, state: state)
    render(conn, :index, issues: issues, owner: owner, repo: repo)
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def create(conn, %{"owner" => owner, "repo" => repo} = params) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)

    case Issues.create_issue(repository, params, conn.assigns.current_user) do
      {:ok, %Issue{} = issue} ->
        conn
        |> put_status(:created)
        |> render(:show, issue: issue, owner: owner, repo: repo)

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
        "issue_number" => issue_number
      }) do
    issue = Issues.get_issue_by_path!(owner, repo, String.to_integer(issue_number))
    render(conn, :show, issue: issue, owner: owner, repo: repo)
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def update(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "issue_number" => issue_number
        } = params
      ) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)
    issue = Issues.get_issue_by_number!(repository, String.to_integer(issue_number))

    case Issues.update_issue(issue, params, conn.assigns.current_user) do
      {:ok, %Issue{} = issue} ->
        render(conn, :show, issue: issue, owner: owner, repo: repo)

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

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{message: "Not Found"})
  end
end
