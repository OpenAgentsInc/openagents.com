defmodule OpenAgentsWeb.IssueController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Forge.Assignments
  alias OpenAgents.Issues
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Agents.Agent
  alias OpenAgents.PullRequests
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.ApiError

  def index(conn, %{"owner" => owner, "repo" => repo} = params) do
    reader = conn.assigns[:current_user]
    repository = Repositories.get_visible_by_path!(owner, repo, reader)

    with :ok <- validate_index_params(params),
         {issues, total} <-
           Issues.list_issues_page(repository, index_options(params, reader)) do
      conn
      |> put_extensions_header()
      |> render(:index,
        issues: issues,
        owner: owner,
        repo: repo,
        dependencies: Issues.dependency_graph(issues),
        progress: Issues.progress_map(issues, reader),
        pull_requests: PullRequests.markers_by_issue_id(issues),
        work: Assignments.attempts_for_issues(issues),
        pagination: %{
          page: Issues.parse_page(params["page"]),
          per_page: Issues.per_page(),
          total: total
        }
      )
    else
      {:error, field, message} ->
        ApiError.validation_failed(conn, %{field => [message]})
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

      Map.has_key?(params, "blocked") and blocked_filter(params["blocked"]) == :invalid ->
        {:error, :blocked, "must be true or false"}

      Map.has_key?(params, "progress") and params["progress"] not in Issues.progress_values() ->
        {:error, :progress, "must be one of: #{Enum.join(Issues.progress_values(), ", ")}"}

      Map.has_key?(params, "type") and params["type"] not in Issues.type_values() ->
        {:error, :type, "must be one of: #{Enum.join(Issues.type_values(), ", ")}"}

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

  defp index_options(params, reader) do
    [
      # GitHub's issues list returns pull requests too and marks them with a
      # `pull_request` object, so this endpoint asks for both by default even
      # though `OpenAgents.Issues` defaults its lists to issues alone. A client
      # that wants one kind without the other sends `?type=`, which GitHub has
      # no counterpart for and which `GET /api/v3` therefore publishes as an
      # `issue.openagents` filter.
      type: Map.get(params, "type", "all"),
      state: Map.get(params, "state", "open"),
      label: params["labels"] || params["label"],
      assignee: params["assignee"],
      milestone: params["milestone"],
      q: params["q"],
      blocked: blocked_filter(params["blocked"]),
      progress: params["progress"],
      reader: reader,
      page: params["page"]
    ]
  end

  # An agent asking "what can I start right now?" sends `blocked=false`. The
  # answer is derived from prerequisite state, so no value other than the two
  # booleans has a meaning to guess at.
  defp blocked_filter(nil), do: nil
  defp blocked_filter("true"), do: true
  defp blocked_filter("false"), do: false
  defp blocked_filter(true), do: true
  defp blocked_filter(false), do: false
  defp blocked_filter(_value), do: :invalid

  def create(conn, %{"owner" => owner, "repo" => repo} = params) do
    actor = conn.assigns[:current_agent] || conn.assigns[:current_user]

    repository =
      case actor do
        %Agent{} -> Repositories.get_public_by_path!(owner, repo)
        _ -> Repositories.get_writable_by_path!(owner, repo, actor)
      end

    if Repositories.issue_participant?(repository, actor) do
      case Issues.create_issue(repository, params, actor) do
        {:ok, %Issue{} = issue} ->
          conn
          |> put_status(:created)
          |> put_extensions_header()
          |> render(:show,
            issue: issue,
            owner: owner,
            repo: repo,
            dependencies: dependencies(issue),
            progress: progress(issue, actor),
            work: work(issue)
          )

        {:error, %Ecto.Changeset{} = changeset} ->
          ApiError.changeset(conn, changeset)
      end
    else
      participation_forbidden(conn, actor)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  # The `error` key predates the envelope and a published agent client reads
  # it, so it rides beside the envelope rather than being replaced.
  defp participation_forbidden(conn, %Agent{}),
    do:
      ApiError.refuse(conn, "agent_participation_forbidden",
        legacy: %{"error" => %{"code" => "agent_participation_forbidden"}}
      )

  defp participation_forbidden(conn, _actor),
    do: ApiError.forbidden(conn, legacy: %{"error" => "forbidden"})

  def show(conn, %{
        "owner" => owner,
        "repo" => repo,
        "issue_number" => issue_number
      }) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])

    issue =
      Issues.get_issue_by_number!(
        repository,
        OpenAgentsWeb.ControllerHelpers.integer_param!(issue_number)
      )

    conn
    |> put_extensions_header()
    |> render(:show,
      issue: issue,
      owner: owner,
      repo: repo,
      dependencies: dependencies(issue),
      progress: progress(issue, conn.assigns[:current_user]),
      pull_requests: PullRequests.markers_by_issue_id([issue]),
      work: work(issue)
    )
  rescue
    Ecto.NoResultsError -> not_found(conn)
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

    issue =
      Issues.get_issue_by_number!(
        repository,
        OpenAgentsWeb.ControllerHelpers.integer_param!(issue_number)
      )

    case Issues.update_issue(issue, params, conn.assigns.current_user) do
      {:ok, %Issue{} = issue} ->
        conn
        |> put_extensions_header()
        |> render(:show,
          issue: issue,
          owner: owner,
          repo: repo,
          dependencies: dependencies(issue),
          progress: progress(issue, conn.assigns.current_user),
          work: work(issue)
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  defp dependencies(%Issue{} = issue), do: Issues.dependency_graph([issue])

  # One issue reads through the same page-shaped function the index uses, so
  # the detail response and a row in the list can never disagree.
  defp work(%Issue{} = issue), do: Assignments.attempts_for_issues([issue])

  # Progress is derived from the boards this reader can open, so an agent
  # authenticating as itself never inherits a private board's column.
  defp progress(%Issue{} = issue, %OpenAgents.Accounts.User{} = reader),
    do: Issues.progress_map([issue], reader)

  defp progress(%Issue{} = issue, _reader), do: Issues.progress_map([issue])

  # The extension namespace is discoverable from the response itself, so a
  # client never has to infer which OpenAgents fields this deployment sends.
  defp put_extensions_header(conn),
    do: put_resp_header(conn, "x-openagents-extensions", "issue.openagents")

  defp not_found(conn), do: ApiError.not_found(conn)
end
