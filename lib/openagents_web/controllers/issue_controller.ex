defmodule OpenAgentsWeb.IssueController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Issue

  def index(conn, %{"owner" => owner, "repo" => repo} = params) do
    state = Map.get(params, "state", "open")
    issues = Issues.list_issues(state: state)
    render(conn, :index, issues: issues, owner: owner, repo: repo)
  end

  def create(conn, %{"owner" => owner, "repo" => repo} = params) do
    case Issues.create_issue(params) do
      {:ok, %Issue{} = issue} ->
        conn
        |> put_status(:created)
        |> render(:show, issue: issue, owner: owner, repo: repo)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  def show(conn, %{
        "owner" => owner,
        "repo" => repo,
        "issue_number" => issue_number
      }) do
    issue = Issues.get_issue_by_number!(String.to_integer(issue_number))
    render(conn, :show, issue: issue, owner: owner, repo: repo)
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def update(conn, %{
        "owner" => owner,
        "repo" => repo,
        "issue_number" => issue_number
      } = params) do
    issue = Issues.get_issue_by_number!(String.to_integer(issue_number))

    case Issues.update_issue(issue, params) do
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
end
