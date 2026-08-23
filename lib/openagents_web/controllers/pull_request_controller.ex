defmodule OpenAgentsWeb.PullRequestController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.PullRequests
  alias OpenAgents.Repositories
  alias OpenAgents.Stacks

  def index(conn, %{"owner" => owner, "repo" => repo}) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])
    pull_requests = PullRequests.list(repository)

    render(conn, :index,
      pull_requests: pull_requests,
      owner: owner,
      repo: repo,
      stack_contexts: Stacks.payload_contexts(repository, pull_requests)
    )
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def show(conn, %{"owner" => owner, "repo" => repo, "pull_number" => number}) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])

    pull_request =
      PullRequests.get_by_number!(
        repository,
        OpenAgentsWeb.ControllerHelpers.integer_param!(number)
      )

    render(conn, :show,
      pull_request: pull_request,
      owner: owner,
      repo: repo,
      stack_contexts: Stacks.payload_contexts(repository, [pull_request])
    )
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def create(conn, %{"owner" => owner, "repo" => repo} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns.current_user)

    case PullRequests.create(repository, params, conn.assigns.current_user) do
      {:ok, pull_request} ->
        conn
        |> put_status(:created)
        |> render(:show, pull_request: pull_request, owner: owner, repo: repo)

      {:error, :pull_requests_disabled} ->
        error(conn, :conflict, "Pull requests are disabled for this repository.")

      {:error, :forbidden} ->
        error(conn, :forbidden, "You cannot open a pull request for this repository.")

      {:error, reason} when reason in [:invalid_ref, :invalid_head_repository] ->
        error(conn, :unprocessable_entity, "The head repository or ref is invalid.")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          errors: Ecto.Changeset.traverse_errors(changeset, fn {message, _} -> message end)
        })
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def update(conn, %{"owner" => owner, "repo" => repo, "pull_number" => number} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns.current_user)

    pull_request =
      PullRequests.get_by_number!(
        repository,
        OpenAgentsWeb.ControllerHelpers.integer_param!(number)
      )

    case PullRequests.update(pull_request, params, conn.assigns.current_user) do
      {:ok, updated} ->
        render(conn, :show, pull_request: updated, owner: owner, repo: repo)

      {:error, :forbidden} ->
        error(conn, :forbidden, "You cannot update this pull request.")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          errors: Ecto.Changeset.traverse_errors(changeset, fn {message, _} -> message end)
        })
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  defp not_found(conn), do: error(conn, :not_found, "Not Found")
  defp error(conn, status, message), do: conn |> put_status(status) |> json(%{message: message})
end
