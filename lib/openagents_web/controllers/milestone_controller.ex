defmodule OpenAgentsWeb.MilestoneController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Milestones
  alias OpenAgents.Milestones.Milestone
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.ApiError

  def index(conn, %{"owner" => owner, "repo" => repo}) do
    repository = Repositories.get_public_by_path!(owner, repo)
    milestones = Milestones.list_milestones(repository)
    render(conn, :index, milestones: milestones, owner: owner, repo: repo)
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def create(conn, %{"owner" => owner, "repo" => repo} = params) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)

    case Milestones.create_milestone(repository, params, conn.assigns.current_user) do
      {:ok, %Milestone{} = milestone} ->
        conn
        |> put_status(:created)
        |> render(:show, milestone: milestone, owner: owner, repo: repo)

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def show(conn, %{
        "owner" => owner,
        "repo" => repo,
        "milestone_number" => milestone_number
      }) do
    milestone =
      Milestones.get_milestone_by_path!(
        owner,
        repo,
        OpenAgentsWeb.ControllerHelpers.integer_param!(milestone_number)
      )

    render(conn, :show, milestone: milestone, owner: owner, repo: repo)
  rescue
    Ecto.NoResultsError -> ApiError.not_found(conn)
  end

  def update(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "milestone_number" => milestone_number
        } = params
      ) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)

    milestone =
      Milestones.get_milestone_by_number!(
        repository,
        OpenAgentsWeb.ControllerHelpers.integer_param!(milestone_number)
      )

    case Milestones.update_milestone(milestone, params) do
      {:ok, %Milestone{} = milestone} ->
        render(conn, :show, milestone: milestone, owner: owner, repo: repo)

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> ApiError.not_found(conn)
  end

  def delete(conn, %{
        "owner" => owner,
        "repo" => repo,
        "milestone_number" => milestone_number
      }) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)

    milestone =
      Milestones.get_milestone_by_number!(
        repository,
        OpenAgentsWeb.ControllerHelpers.integer_param!(milestone_number)
      )

    case Milestones.delete_milestone(milestone) do
      {:ok, %Milestone{}} ->
        send_resp(conn, :no_content, "")

      {:error, _reason} ->
        ApiError.refuse(conn, "delete_failed", message: "Could not delete milestone")
    end
  rescue
    Ecto.NoResultsError -> ApiError.not_found(conn)
  end

  defp not_found(conn), do: ApiError.not_found(conn)
end
