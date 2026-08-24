defmodule OpenAgentsWeb.CommentController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Comment
  alias OpenAgents.Agents.Agent
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.ApiError

  import OpenAgentsWeb.ControllerHelpers, only: [integer_param!: 1, lookup: 1]

  def index(conn, %{
        "owner" => owner,
        "repo" => repo,
        "issue_number" => issue_number
      }) do
    reader = conn.assigns[:current_user]

    with {:ok, repository} <-
           lookup(fn -> Repositories.get_visible_by_path!(owner, repo, reader) end),
         {:ok, issue} <-
           lookup(fn ->
             Issues.get_issue_by_number!(repository, integer_param!(issue_number))
           end) do
      render(conn, :index, comments: Issues.list_comments(issue))
    else
      {:error, :not_found} -> ApiError.not_found(conn)
    end
  end

  def create(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "issue_number" => issue_number
        } = params
      ) do
    actor = conn.assigns[:current_agent] || conn.assigns[:current_user]

    with {:ok, repository} <- lookup(fn -> write_repository(owner, repo, actor) end),
         {:ok, issue} <-
           lookup(fn ->
             Issues.get_issue_by_number!(repository, integer_param!(issue_number))
           end) do
      if Repositories.issue_participant?(repository, actor) do
        # Nothing between here and the write resolves a name, so this action has
        # only ever had one door. It is written this way anyway: the rescue that
        # was here covered the write too, and a lookup added inside it later
        # would have joined the repository's `404` without anyone deciding to.
        case Issues.create_comment(issue, params, actor) do
          {:ok, %Comment{} = comment} ->
            conn
            |> put_status(:created)
            |> render(:show, comment: comment)

          {:error, %Ecto.Changeset{} = changeset} ->
            ApiError.changeset(conn, changeset)
        end
      else
        participation_forbidden(conn, actor)
      end
    else
      {:error, :not_found} -> ApiError.not_found(conn)
    end
  end

  defp write_repository(owner, repo, %Agent{}), do: Repositories.get_public_by_path!(owner, repo)

  defp write_repository(owner, repo, actor),
    do: Repositories.get_writable_by_path!(owner, repo, actor)

  # The `error` key predates the envelope and a published agent client reads
  # it, so it rides beside the envelope rather than being replaced.
  defp participation_forbidden(conn, %Agent{}),
    do:
      ApiError.refuse(conn, "agent_participation_forbidden",
        legacy: %{"error" => %{"code" => "agent_participation_forbidden"}}
      )

  defp participation_forbidden(conn, _actor),
    do: ApiError.forbidden(conn, legacy: %{"error" => "forbidden"})

  def show(conn, %{"owner" => owner, "repo" => repo, "id" => id}) do
    reader = conn.assigns[:current_user]

    with {:ok, repository} <-
           lookup(fn -> Repositories.get_visible_by_path!(owner, repo, reader) end),
         {:ok, comment} <-
           lookup(fn -> Issues.get_comment!(repository, integer_param!(id)) end) do
      render(conn, :show, comment: comment)
    else
      {:error, :not_found} -> ApiError.not_found(conn)
    end
  end

  def update(conn, %{"owner" => owner, "repo" => repo, "id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, repository} <-
           lookup(fn -> Repositories.get_writable_by_path!(owner, repo, user) end),
         {:ok, comment} <-
           lookup(fn -> Issues.get_comment!(repository, integer_param!(id)) end) do
      case Issues.update_comment(comment, params) do
        {:ok, %Comment{} = comment} ->
          render(conn, :show, comment: comment)

        {:error, %Ecto.Changeset{} = changeset} ->
          ApiError.changeset(conn, changeset)
      end
    else
      {:error, :not_found} -> ApiError.not_found(conn)
    end
  end

  def delete(conn, %{"owner" => owner, "repo" => repo, "id" => id}) do
    user = conn.assigns.current_user

    with {:ok, repository} <-
           lookup(fn -> Repositories.get_writable_by_path!(owner, repo, user) end),
         {:ok, comment} <-
           lookup(fn -> Issues.get_comment!(repository, integer_param!(id)) end) do
      case Issues.delete_comment(comment) do
        {:ok, :ok} ->
          send_resp(conn, :no_content, "")

        {:error, _reason} ->
          ApiError.refuse(conn, "delete_failed", message: "Could not delete comment")
      end
    else
      {:error, :not_found} -> ApiError.not_found(conn)
    end
  end
end
