defmodule OpenAgentsWeb.IssueLabelController do
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

    json(conn, %{labels: issue.labels || []})
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

    names = params["labels"] || []

    case Issues.add_labels(issue, names, conn.assigns.current_user) do
      {:ok, %Issues.Issue{} = issue} ->
        json(conn, %{labels: issue.labels})

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> ApiError.not_found(conn)
  end

  def delete(conn, %{
        "owner" => owner,
        "repo" => repo,
        "issue_number" => issue_number,
        "name" => name
      }) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)

    issue =
      Issues.get_issue_by_number!(
        repository,
        OpenAgentsWeb.ControllerHelpers.integer_param!(issue_number)
      )

    decoded = URI.decode(name)

    if Enum.any?(issue.labels || [], &(&1["name"] == decoded)) do
      case Issues.remove_label(issue, name, conn.assigns.current_user) do
        {:ok, %Issues.Issue{} = issue} ->
          json(conn, %{labels: issue.labels})

        {:error, _reason} ->
          ApiError.refuse(conn, "delete_failed", message: "Could not remove label")
      end
    else
      # GitHub refuses to remove a label the issue does not wear; a silent
      # no-op hides the mismatch from the script that sent it.
      ApiError.refuse(conn, "label_not_on_issue")
    end
  rescue
    Ecto.NoResultsError -> ApiError.not_found(conn)
  end
end
