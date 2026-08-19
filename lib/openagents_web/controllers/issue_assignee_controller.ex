defmodule OpenAgentsWeb.IssueAssigneeController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Issues

  def index(conn, %{"owner" => _owner, "repo" => _repo, "issue_number" => issue_number}) do
    issue = Issues.get_issue_by_number!(String.to_integer(issue_number))
    json(conn, %{assignees: issue.assignees || []})
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def create(conn, %{
        "owner" => _owner,
        "repo" => _repo,
        "issue_number" => issue_number
      } = params) do
    issue = Issues.get_issue_by_number!(String.to_integer(issue_number))
    logins = params["assignees"] || []

    case Issues.add_assignees(issue, logins) do
      {:ok, %Issues.Issue{} = issue} ->
        json(conn, %{assignees: issue.assignees})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, & &1)})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end

  def delete(conn, %{
        "owner" => _owner,
        "repo" => _repo,
        "issue_number" => issue_number
      } = params) do
    issue = Issues.get_issue_by_number!(String.to_integer(issue_number))
    logins = params["assignees"] || []

    case Issues.remove_assignees(issue, logins) do
      {:ok, %Issues.Issue{} = issue} ->
        json(conn, %{assignees: issue.assignees})

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{message: "Could not remove assignees"})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end
end
