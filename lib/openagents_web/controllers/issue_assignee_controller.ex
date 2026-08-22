defmodule OpenAgentsWeb.IssueAssigneeController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Issues
  alias OpenAgents.Repositories

  def index(conn, %{"owner" => owner, "repo" => repo, "issue_number" => issue_number}) do
    issue =
      Issues.get_issue_by_path!(
        owner,
        repo,
        OpenAgentsWeb.ControllerHelpers.integer_param!(issue_number)
      )

    json(conn, %{assignees: issue.assignees || []})
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

    issue =
      Issues.get_issue_by_number!(
        repository,
        OpenAgentsWeb.ControllerHelpers.integer_param!(issue_number)
      )

    logins = params["assignees"] || []

    case Issues.add_assignees(issue, logins) do
      {:ok, %Issues.Issue{} = issue} ->
        json(conn, %{assignees: issue.assignees})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
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

  defp translate_error({message, options}) do
    Regex.replace(~r/%{(\w+)}/, message, fn _, key ->
      options |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
