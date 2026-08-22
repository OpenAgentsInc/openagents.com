defmodule OpenAgentsWeb.IssueController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Repositories

  def index(conn, %{"owner" => owner, "repo" => repo} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])

    with :ok <- validate_index_params(params),
         {issues, total} <-
           Issues.list_issues_page(repository, index_options(params)) do
      render(conn, :index,
        issues: issues,
        owner: owner,
        repo: repo,
        pagination: %{
          page: Issues.parse_page(params["page"]),
          per_page: Issues.per_page(),
          total: total
        }
      )
    else
      {:error, field, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{field => [message]}})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  @valid_states ~w(open closed all)

  # Every list is bounded by Issues' fixed page size, and every filter value is
  # either accepted as-is or rejected with one stable field-level error.
  defp validate_index_params(params) do
    state = Map.get(params, "state", "open")

    cond do
      state not in @valid_states ->
        {:error, :state, "must be one of: #{Enum.join(@valid_states, ", ")}"}

      Map.has_key?(params, "page") and not valid_page?(params["page"]) ->
        {:error, :page, "must be a positive integer"}

      true ->
        :ok
    end
  end

  defp valid_page?(value) when is_integer(value) and value >= 1, do: true

  defp valid_page?(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> valid_page?(number)
      _other -> false
    end
  end

  defp valid_page?(_value), do: false

  defp index_options(params) do
    [
      state: Map.get(params, "state", "open"),
      label: params["labels"] || params["label"],
      assignee: params["assignee"],
      milestone: params["milestone"],
      q: params["q"],
      page: params["page"]
    ]
  end

  def create(conn, %{"owner" => owner, "repo" => repo} = params) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)

    case Issues.create_issue(repository, params, conn.assigns.current_user) do
      {:ok, %Issue{} = issue} ->
        conn
        |> put_status(:created)
        |> render(:show, issue: issue, owner: owner, repo: repo)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def show(conn, %{
        "owner" => owner,
        "repo" => repo,
        "issue_number" => issue_number
      }) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])
    issue = Issues.get_issue_by_number!(repository, String.to_integer(issue_number))
    render(conn, :show, issue: issue, owner: owner, repo: repo)
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
          "issue_number" => issue_number
        } = params
      ) do
    repository = Repositories.get_writable_by_path!(owner, repo, conn.assigns.current_user)
    issue = Issues.get_issue_by_number!(repository, String.to_integer(issue_number))

    case Issues.update_issue(issue, params, conn.assigns.current_user) do
      {:ok, %Issue{} = issue} ->
        render(conn, :show, issue: issue, owner: owner, repo: repo)

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

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{message: "Not Found"})
  end
end
