defmodule OpenAgentsWeb.IssueLabelController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Issues
  alias OpenAgents.Repositories

  def index(conn, %{"owner" => owner, "repo" => repo, "issue_number" => issue_number}) do
    issue = Issues.get_issue_by_path!(owner, repo, String.to_integer(issue_number))
    json(conn, %{labels: issue.labels || []})
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
    names = params["labels"] || []

    case Issues.add_labels(issue, names) do
      {:ok, %Issues.Issue{} = issue} ->
        json(conn, %{labels: issue.labels})

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
        "owner" => owner,
        "repo" => repo,
        "issue_number" => issue_number,
        "name" => name
      }) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)
    issue = Issues.get_issue_by_number!(repository, String.to_integer(issue_number))

    case Issues.remove_label(issue, name) do
      {:ok, %Issues.Issue{} = issue} ->
        json(conn, %{labels: issue.labels})

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{message: "Could not remove label"})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end
end
