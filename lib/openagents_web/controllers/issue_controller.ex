defmodule OpenAgentsWeb.IssueController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Forge.Assignments
  alias OpenAgents.Issues
  alias OpenAgents.Issues.CompletionClaims
  alias OpenAgents.Issues.Evidence
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Issues.UnknownReference
  alias OpenAgents.Agents.Agent
  alias OpenAgents.PullRequests
  alias OpenAgents.Repositories
  alias OpenAgents.Transparency.WorkDisclosure
  alias OpenAgentsWeb.ApiError

  import OpenAgentsWeb.ControllerHelpers, only: [integer_param!: 1, lookup: 1]

  def index(conn, %{"owner" => owner, "repo" => repo} = params) do
    reader = conn.assigns[:current_user]

    with {:ok, repository} <-
           lookup(fn -> Repositories.get_visible_by_path!(owner, repo, reader) end),
         :ok <- validate_index_params(params) do
      {issues, total} = Issues.list_issues_page(repository, index_options(params, reader))

      conn
      |> put_extensions_header()
      |> render(:index,
        issues: issues,
        owner: owner,
        repo: repo,
        dependencies: Issues.dependency_graph(issues),
        progress: Issues.progress_map(issues, reader),
        pull_requests: PullRequests.markers_by_issue_id(issues),
        work: Assignments.attempts_for_issues(issues, viewer(repository, reader)),
        evidence: Evidence.for_issues(issues, viewer(repository, reader)),
        completion_claims: CompletionClaims.for_issues(issues),
        pagination: %{
          page: Issues.parse_page(params["page"]),
          per_page: Issues.per_page(),
          total: total
        }
      )
    else
      {:error, :not_found} ->
        not_found(conn)

      {:error, field, message} ->
        ApiError.validation_failed(conn, %{field => [message]})
    end
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

    case lookup(fn -> write_repository(owner, repo, actor) end) do
      {:error, :not_found} ->
        not_found(conn)

      {:ok, repository} ->
        if Repositories.issue_participant?(repository, actor) do
          create_issue(conn, repository, params, actor, owner, repo)
        else
          participation_forbidden(conn, actor)
        end
    end
  end

  # An agent reaches a public repository it is not a member of; a person needs
  # write access. Either way this is the repository lookup, and it is the only
  # thing `lookup/1` wraps: whatever it refuses is a `404` that discloses
  # nothing about whether the repository exists.
  defp write_repository(owner, repo, %Agent{}), do: Repositories.get_public_by_path!(owner, repo)

  defp write_repository(owner, repo, actor),
    do: Repositories.get_writable_by_path!(owner, repo, actor)

  defp create_issue(conn, repository, params, actor, owner, repo) do
    case write_issue(fn -> Issues.create_issue(repository, params, actor) end) do
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
          work: work(issue, repository, actor),
          evidence: evidence(issue, repository, actor),
          completion_claims: completion_claims(issue)
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)

      {:error, %UnknownReference{} = unresolved} ->
        unknown_reference(conn, unresolved)
    end
  end

  # Writing an issue resolves a label, an assignee, and a milestone by name, and
  # a name this repository does not have is a rejected field rather than a
  # missing resource. It is caught here rather than beside the repository
  # lookup, so the two failures leave by different doors.
  defp write_issue(write) do
    write.()
  rescue
    error in UnknownReference -> {:error, error}
  end

  # GitHub names the offending field, and so does this: the envelope's `errors`
  # map carries the request-body key and the value that did not resolve.
  defp unknown_reference(conn, %UnknownReference{} = error) do
    ApiError.validation_failed(conn, %{error.field => [Exception.message(error)]})
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
    reader = conn.assigns[:current_user]

    with {:ok, repository} <-
           lookup(fn -> Repositories.get_visible_by_path!(owner, repo, reader) end),
         {:ok, issue} <-
           lookup(fn ->
             Issues.get_issue_by_number!(repository, integer_param!(issue_number))
           end) do
      conn
      |> put_extensions_header()
      |> render(:show,
        issue: issue,
        owner: owner,
        repo: repo,
        dependencies: dependencies(issue),
        progress: progress(issue, reader),
        pull_requests: PullRequests.markers_by_issue_id([issue]),
        work: work(issue, repository, reader),
        evidence: evidence(issue, repository, reader),
        completion_claims: completion_claims(issue)
      )
    else
      {:error, :not_found} -> not_found(conn)
    end
  end

  def update(
        conn,
        %{
          "owner" => owner,
          "repo" => repo,
          "issue_number" => issue_number
        } = params
      ) do
    user = conn.assigns.current_user

    with {:ok, repository} <-
           lookup(fn -> Repositories.get_writable_by_path!(owner, repo, user) end),
         {:ok, issue} <-
           lookup(fn ->
             Issues.get_issue_by_number!(repository, integer_param!(issue_number))
           end) do
      case write_issue(fn -> Issues.update_issue(issue, params, user) end) do
        {:ok, %Issue{} = issue} ->
          conn
          |> put_extensions_header()
          |> render(:show,
            issue: issue,
            owner: owner,
            repo: repo,
            dependencies: dependencies(issue),
            progress: progress(issue, user),
            work: work(issue, repository, user),
            evidence: evidence(issue, repository, user),
            completion_claims: completion_claims(issue)
          )

        {:error, %Ecto.Changeset{} = changeset} ->
          ApiError.changeset(conn, changeset)

        {:error, %UnknownReference{} = unresolved} ->
          unknown_reference(conn, unresolved)
      end
    else
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp dependencies(%Issue{} = issue), do: Issues.dependency_graph([issue])

  # One issue reads through the same page-shaped function the index uses, so
  # the detail response and a row in the list can never disagree.
  defp work(%Issue{} = issue, repository, reader),
    do: Assignments.attempts_for_issues([issue], viewer(repository, reader))

  # The evidence chain reads through the same page-shaped function as the
  # index, for the same reason: a detail response and a row in the list can
  # never disagree about what shipped an issue.
  defp evidence(%Issue{} = issue, repository, reader),
    do: Evidence.for_issues([issue], viewer(repository, reader))

  # One viewer descriptor, built the same way for every action, so the API and
  # the issue page cannot disagree about which rung a reader is on. An API
  # caller authenticating as an agent is not a repository member and lands on
  # `pulse`, which is the same answer anonymous web traffic gets.
  defp viewer(repository, reader), do: WorkDisclosure.viewer(repository, reader)

  # The claims read through the same page-shaped function as the index, for the
  # same reason: a detail response and a row in the list can never disagree
  # about what was claimed for an issue.
  defp completion_claims(%Issue{} = issue), do: CompletionClaims.for_issues([issue])

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
