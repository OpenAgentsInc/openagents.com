defmodule OpenAgentsWeb.IssueAssigneeController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Issues
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.ApiError

  def index(conn, %{"owner" => owner, "repo" => repo, "issue_number" => issue_number}) do
    issue =
      Issues.get_issue_by_path!(
        owner,
        repo,
        OpenAgentsWeb.ControllerHelpers.integer_param!(issue_number)
      )

    json(conn, %{assignees: issue.assignees || []})
  rescue
    Ecto.NoResultsError -> ApiError.not_found(conn)
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

    issue =
      Issues.get_issue_by_number!(
        repository,
        OpenAgentsWeb.ControllerHelpers.integer_param!(issue_number)
      )

    logins = params["assignees"] || []

    case Issues.add_assignees(issue, logins, conn.assigns.current_user) do
      {:ok, %Issues.Issue{} = issue} ->
        json(conn, %{assignees: issue.assignees})

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> ApiError.not_found(conn)
  end

  def delete(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "issue_number" => issue_number
        } = params
      ) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)

    issue =
      Issues.get_issue_by_number!(
        repository,
        OpenAgentsWeb.ControllerHelpers.integer_param!(issue_number)
      )

    logins = params["assignees"] || []

    case Issues.remove_assignees(issue, logins, conn.assigns.current_user) do
      {:ok, %Issues.Issue{} = issue} ->
        json(conn, %{assignees: issue.assignees})

      {:error, _reason} ->
        ApiError.refuse(conn, "delete_failed", message: "Could not remove assignees")
    end
  rescue
    Ecto.NoResultsError -> ApiError.not_found(conn)
  end
end
