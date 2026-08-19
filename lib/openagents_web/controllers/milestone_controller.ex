defmodule OpenAgentsWeb.MilestoneController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Milestones
  alias OpenAgents.Milestones.Milestone

  def index(conn, %{"owner" => owner, "repo" => repo}) do
    milestones = Milestones.list_milestones()
    render(conn, :index, milestones: milestones, owner: owner, repo: repo)
  end

  def create(conn, %{"owner" => owner, "repo" => repo} = params) do
    case Milestones.create_milestone(params) do
      {:ok, %Milestone{} = milestone} ->
        conn
        |> put_status(:created)
        |> render(:show, milestone: milestone, owner: owner, repo: repo)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  def show(conn, %{
        "owner" => owner,
        "repo" => repo,
        "milestone_number" => milestone_number
      }) do
    milestone = Milestones.get_milestone_by_number!(String.to_integer(milestone_number))
    render(conn, :show, milestone: milestone, owner: owner, repo: repo)
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
          "milestone_number" => milestone_number
        } = params
      ) do
    milestone = Milestones.get_milestone_by_number!(String.to_integer(milestone_number))

    case Milestones.update_milestone(milestone, params) do
      {:ok, %Milestone{} = milestone} ->
        render(conn, :show, milestone: milestone, owner: owner, repo: repo)

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

  def delete(conn, %{
        "owner" => _owner,
        "repo" => _repo,
        "milestone_number" => milestone_number
      }) do
    milestone = Milestones.get_milestone_by_number!(String.to_integer(milestone_number))

    case Milestones.delete_milestone(milestone) do
      {:ok, %Milestone{}} ->
        send_resp(conn, :no_content, "")

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{message: "Could not delete milestone"})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{message: "Not Found"})
  end
end
