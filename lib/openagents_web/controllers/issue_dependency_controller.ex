defmodule OpenAgentsWeb.IssueDependencyController do
  @moduledoc """
  Prerequisite edges between the issues of one repository.

  The response is the same object the issue extension carries, so a client that
  reads `issue.openagents` and a client that reads this endpoint agree without
  translating between two shapes.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Issues
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.ControllerHelpers

  def index(conn, %{"owner" => owner, "repo" => repo, "issue_number" => issue_number}) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])

    issue =
      Issues.get_issue_by_number!(repository, ControllerHelpers.integer_param!(issue_number))

    json(conn, Issues.dependencies(issue))
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def create(
        conn,
        %{"owner" => owner, "repo" => repo, "issue_number" => issue_number} = params
      ) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)

    issue =
      Issues.get_issue_by_number!(repository, ControllerHelpers.integer_param!(issue_number))

    case params["blocked_by"] do
      numbers when is_list(numbers) ->
        add_dependencies(conn, issue, numbers)

      _other ->
        unprocessable(conn, "must be a list of issue numbers in this repository")
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def delete(conn, %{
        "owner" => owner,
        "repo" => repo,
        "issue_number" => issue_number,
        "blocked_by_number" => blocked_by_number
      }) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)

    issue =
      Issues.get_issue_by_number!(repository, ControllerHelpers.integer_param!(issue_number))

    case Issues.remove_dependency(issue, blocked_by_number) do
      :ok ->
        json(conn, Issues.dependencies(issue))

      {:error, {:missing_dependency, number}} ->
        message(conn, :not_found, "Issue ##{number} is not a prerequisite of this issue")

      {:error, {:missing_issue, number}} ->
        message(conn, :not_found, "Issue ##{number} does not exist in this repository")

      {:error, {:invalid_number, _value}} ->
        not_found(conn)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  defp add_dependencies(conn, issue, numbers) do
    case Issues.add_dependencies(issue, numbers, conn.assigns.current_user) do
      :ok ->
        conn |> put_status(:created) |> json(Issues.dependencies(issue))

      {:error, reason} ->
        unprocessable(conn, error_message(reason))
    end
  end

  defp error_message({:invalid_number, value}),
    do: "#{inspect(value)} is not an issue number"

  defp error_message({:self_reference, number}),
    do: "Issue ##{number} cannot be a prerequisite of itself"

  defp error_message({:missing_issue, number}),
    do: "Issue ##{number} does not exist in this repository"

  defp error_message({:cycle, numbers}),
    do: "Would create a dependency cycle: #{Enum.map_join(numbers, " -> ", &"##{&1}")}"

  defp error_message({:invalid_dependency, changeset}) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _options} -> message end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end

  defp unprocessable(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{blocked_by: [message]}})
  end

  defp message(conn, status, message) do
    conn |> put_status(status) |> json(%{message: message})
  end

  defp not_found(conn), do: message(conn, :not_found, "Not Found")
end
