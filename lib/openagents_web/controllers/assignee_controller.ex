defmodule OpenAgentsWeb.AssigneeController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Repositories

  def index(conn, %{"owner" => owner, "repo" => repo}) do
    assignees =
      owner
      |> Repositories.get_public_by_path!(repo)
      |> Repositories.list_assignable_users()
      |> Enum.map(&projection/1)

    json(conn, %{assignees: assignees})
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def show(conn, %{"owner" => owner, "repo" => repo, "assignee" => login}) do
    assignee =
      owner
      |> Repositories.get_public_by_path!(repo)
      |> Repositories.get_assignable_user_by_login!(login)

    json(conn, projection(assignee))
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  defp projection(user) do
    %{
      id: user.github_id,
      login: user.github_login,
      avatar_url: user.github_avatar_url
    }
  end

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{message: "Not Found"})
  end
end
